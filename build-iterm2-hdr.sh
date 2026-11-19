#!/bin/bash
# Builds iTerm2 with "HDR text in focused pane" (iterm2-hdr-text.patch) and
# installs it as ~/Applications/iTerm2 HDR.app, next to your normal iTerm2.
#
# Usage:  bash build-iterm2-hdr.sh          (patch file must sit next to this script)
#         ITERM_SRC=~/code/iTerm2 bash build-iterm2-hdr.sh   (use another checkout dir)
#
# Safe to re-run after a failure: each stage remembers when it has finished.
#
# On older SDKs, temporarily adapt the Foundation Models calls for the
# installed API. Without token counting, AI tab titles use their existing
# prompt-length estimate. Keep warnings nonfatal on older compilers.
#
# Stages:
#   1. Check Xcode.
#   2. Clone iTerm2 and apply the patch (once).
#   3. iTerm2's one-time toolchain setup, `make setup` (interactive).
#   4. Build the native dependencies, once per Xcode version. Same as
#      `make paranoid-deps`, minus the step that regenerates the SF Symbols
#      list: it crashes on some SF Symbols app versions, and its output is
#      already committed to the repo, so the committed copy is used.
#   5. Build iTerm2 (optimized) and install it.
#
# After it finishes:
#   1. Quit your normal iTerm2 (two copies with the same bundle ID fight over
#      settings), then open ~/Applications/iTerm2 HDR.app.
#   2. Settings > Profiles > Colors: tick "HDR text in focused pane", pick a
#      brightness. With "Use separate colors for light and dark mode" on, you
#      can enable it for light mode only.
#   3. Settings > Advanced, search "Night Shift" to change the Night Shift rule.
#   4. Settings > General > Magic: untick "Disable GPU rendering when
#      disconnected from power" if you want HDR text on battery.
#   5. Settings > General: turn off automatic update checks, or Sparkle may
#      replace this build with a stock release.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCH="$SCRIPT_DIR/iterm2-hdr-text.patch"
SRC="${ITERM_SRC:-$HOME/src/iTerm2-hdr}"
# The iTerm2 commit the patch was written against (master, Nov 13 2026).
BASE_COMMIT=b3010f0d41a1ee9b0bebbc751b1342d428616cc2
DEST="$HOME/Applications/iTerm2 HDR.app"
SHIM_FILE="sources/AITerm/AppleIntelligenceRunner.swift"
SHIM_MARKER="Local build shim added by build-iterm2-hdr.sh"
# Files the HDR text patch touches, for the warning report in compatibility mode.
PATCHED_FILES='iTermCursor|iTermTextDrawingHelper|iTermMetalPerFrameState|iTermTextRenderer|iTermShaderTypes|iTermText\.metal|iTermMetalDriver|PTYSession|SessionView|PTYTextView|ProfilesColorsPreferencesViewController|iTermProfilePreferences|iTermAdvancedSettingsModel|iTermRecordingProfileSanitizer'

step() { printf '\n==> %s\n' "$*"; }

# True when version $1 >= version $2, comparing up to three dotted parts.
version_at_least() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        split(a, x, "."); split(b, y, ".")
        for (i = 1; i <= 3; i++) {
            if ((x[i] + 0) > (y[i] + 0)) exit 0
            if ((x[i] + 0) < (y[i] + 0)) exit 1
        }
        exit 0
    }'
}

if [ ! -f "$PATCH" ]; then
    echo "Can't find $PATCH. Keep the patch next to this script." >&2
    exit 1
fi

# --- 1. Xcode check ---------------------------------------------------------
step "Checking Xcode"
if ! XCODE_VERSION="$(xcodebuild -version 2>/dev/null)"; then
    echo "xcodebuild isn't working. Install Xcode from the App Store, then run:" >&2
    echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    echo "  sudo xcodebuild -license accept" >&2
    exit 1
fi
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
echo "$XCODE_VERSION" | head -1
echo "macOS SDK $SDK_VERSION"
if ! version_at_least "$SDK_VERSION" "26.0"; then
    echo "iTerm2 needs Xcode 26 or newer (macOS 26 SDK). Update Xcode first." >&2
    exit 1
fi
COMPAT=0
if ! version_at_least "$SDK_VERSION" "26.4"; then
    COMPAT=1
    echo "Older than the macOS 26.4 SDK: building in compatibility mode (see top of this script)."
fi
# Xcode 26 and later ship the Metal shader compiler as a separate download.
if ! xcrun metal --version >/dev/null 2>&1; then
    step "Downloading the Metal toolchain for this Xcode"
    xcodebuild -downloadComponent MetalToolchain
fi

# --- 2. Source + patch ------------------------------------------------------
if [ ! -d "$SRC/.git" ]; then
    step "Cloning iTerm2 into $SRC"
    mkdir -p "$(dirname "$SRC")"
    git clone https://github.com/gnachman/iTerm2.git "$SRC"
fi
cd "$SRC"

# Undo a stand-in left behind if an earlier run was killed mid-build.
remove_shim() {
    # Only remove the appended block. Preserve pre-existing local edits.
    sed -i '' "/^\/\/ ---- $SHIM_MARKER/,$ d" "$SHIM_FILE"
}
if grep -Fq "$SHIM_MARKER" "$SHIM_FILE" 2>/dev/null; then
    remove_shim
fi

if git rev-parse -q --verify refs/heads/hdr-text >/dev/null; then
    step "Using existing hdr-text branch"
    git checkout -q hdr-text
else
    step "Applying the HDR text patch"
    git fetch -q origin
    # Prefer the newest master so you get upstream fixes; fall back to the
    # exact commit the patch was made on if master has moved too far.
    git checkout -q -b hdr-text origin/master
    if git am -q --3way "$PATCH"; then
        echo "Patch applied on latest master."
    else
        echo "Patch did not apply cleanly on latest master; using $BASE_COMMIT instead."
        git am --abort
        git checkout -q -B hdr-text "$BASE_COMMIT"
        git am -q "$PATCH"
    fi
fi

# --- 3. Toolchain setup (once) ----------------------------------------------
SETUP_MARKER="$SRC/.git/hdr-text-setup-done"
if [ ! -f "$SETUP_MARKER" ]; then
    step "One-time toolchain setup (make setup). Answer y to its questions."
    make setup
    touch "$SETUP_MARKER"
fi
# Keep submodules on the commits this branch expects.
git submodule update --init --recursive

BUILD_DIR="$(xcodebuild -scheme iTerm2 -showBuildSettings 2>/dev/null | awk -F ' = ' '/^ *SYMROOT/ && !found {print $2; found=1}')"

# --- 4. Native dependencies (once per Xcode version) ------------------------
DEPS_MARKER="$SRC/.git/hdr-text-deps-xcode"
if [ ! -f "$DEPS_MARKER" ] || [ "$(cat "$DEPS_MARKER")" != "$XCODE_VERSION" ]; then
    step "Building native dependencies (slow the first time, no downloads needed)"
    # A crashed SF Symbols step can leave its generated files empty; put back
    # the committed versions.
    git checkout -- ThirdParty/SFSymbolEnum
    # Same targets and sandbox as `make paranoid-deps`, without `sfsymbolenum`.
    /usr/bin/sandbox-exec -f deps.sb make BUILD_DIR="$BUILD_DIR" \
        fatlibsixel CoreParse NMSSH bindeps libgit2 sparkle librailroad_dsl pwmadapters
    git checkout -- ThirdParty/SFSymbolEnum
    # The Xcode project refuses to build unless this file matches your Xcode,
    # which is how it knows the dependencies above match. Record it, and tell
    # git to ignore the local change so it never ends up in a commit or PR.
    xcodebuild -version > last-xcode-version
    git update-index --skip-worktree last-xcode-version
    printf '%s' "$XCODE_VERSION" > "$DEPS_MARKER"
fi

# --- 5. Build + install -----------------------------------------------------
MAKE_ARGS=()
# The sampling argument was renamed separately from the token-count API.
# Probe the SDK so intermediate Xcode releases get just the shim they need.
NEEDS_SAMPLING_SHIM=0
if ! xcrun swiftc -typecheck - >/dev/null 2>&1 <<'EOF'
import FoundationModels
@available(macOS 26.0, *)
func check() { _ = GenerationOptions(samplingMode: .greedy) }
EOF
then
    NEEDS_SAMPLING_SHIM=1
fi
if [ "$COMPAT" = 1 ] || [ "$NEEDS_SAMPLING_SHIM" = 1 ]; then
    step "Adapting Foundation Models calls for the installed SDK"
    trap remove_shim EXIT
    echo "// ---- $SHIM_MARKER. Never commit this. ----" >> "$SHIM_FILE"
fi
if [ "$NEEDS_SAMPLING_SHIM" = 1 ]; then
    cat >> "$SHIM_FILE" <<'EOF'
@available(macOS 26.0, *)
private extension GenerationOptions {
    init(samplingMode: SamplingMode, maximumResponseTokens: Int? = nil) {
        self.init(sampling: samplingMode, maximumResponseTokens: maximumResponseTokens)
    }
}
EOF
fi
if [ "$COMPAT" = 1 ]; then
    cat >> "$SHIM_FILE" <<'EOF'
private struct TokenCountUnavailableInThisSDK: Error {}

@available(macOS 26.0, *)
extension SystemLanguageModel {
    func tokenCount(for instructions: Instructions) async throws -> Int {
        throw TokenCountUnavailableInThisSDK()
    }
    func tokenCount(for schema: GenerationSchema) async throws -> Int {
        throw TokenCountUnavailableInThisSDK()
    }
    func tokenCount(for prompt: String) async throws -> Int {
        throw TokenCountUnavailableInThisSDK()
    }
}
EOF
    # Pass extra build settings through the Makefile's SIGNING_FLAGS variable,
    # keeping its default "no code signing" settings.
    MAKE_ARGS+=('SIGNING_FLAGS=CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=NO GCC_TREAT_WARNINGS_AS_ERRORS=NO')
fi

# Deployment = optimized, no Address Sanitizer. (The Development build is
# unoptimized with ASan on, which is too slow to use as your daily terminal.)
mkdir -p "$SRC/tmp"
LOG="$SRC/tmp/build.log"
step "Building iTerm2 (about 10-20 minutes). Full log: $LOG"
APP="$BUILD_DIR/Deployment/iTerm2.app"
if ! make Deployment BUILD_DIR="$BUILD_DIR" ${MAKE_ARGS[@]+"${MAKE_ARGS[@]}"} > "$LOG" 2>&1; then
    # `make Deployment` also extracts localizable strings after compiling. If
    # only that last part failed, the app is fine to use.
    if grep -q "\*\* BUILD SUCCEEDED \*\*" "$LOG" && [ -d "$APP" ]; then
        echo "The app compiled; a step after compiling failed, which doesn't affect it."
    else
        echo ""
        echo "Build failed. Errors:"
        echo "-----------------------------------"
        { grep -E "error:" "$LOG" | grep -v "CLANG_WARN\|GCC_TREAT\|export " | sort -u | head -40; } || true
        echo "-----------------------------------"
        echo "Paste the lines above (and this file if it's unclear): $LOG"
        exit 1
    fi
fi

if [ "$COMPAT" = 1 ]; then
    WARNINGS="$(grep -E "warning:" "$LOG" | grep -E "$PATCHED_FILES" | sort -u | head -30 || true)"
    if [ -n "$WARNINGS" ]; then
        step "Compiler warnings in files the HDR patch touches (paste these to Claude)"
        echo "$WARNINGS"
    fi
fi

if [ ! -d "$APP" ]; then
    echo "Build finished but $APP is missing." >&2
    exit 1
fi

step "Installing"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
# The build is unsigned; give it an ad-hoc signature so macOS will launch it.
codesign --force --deep --sign - "$DEST"
codesign --verify --deep --strict "$DEST"

echo ""
echo "Installed: $DEST"
echo "Quit your normal iTerm2, then: open \"$DEST\""
