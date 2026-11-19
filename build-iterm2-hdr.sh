#!/bin/bash
# Builds iTerm2 with "HDR text in focused pane" (iterm2-hdr-text.patch), installs
# it as ~/Applications/iTerm2 HDR.app next to your normal iTerm2, and keeps it up
# to date with new iTerm2 commits.
#
# Usage:
#   bash build-iterm2-hdr.sh             Build the current checkout and install it.
#   bash build-iterm2-hdr.sh --update    Pull the newest iTerm2, put the patch back
#                                        on top, rebuild and install.
#   bash build-iterm2-hdr.sh --schedule  Check for updates in the background once a
#                                        week. --unschedule turns that off.
#   bash build-iterm2-hdr.sh --rollback  Put back the build the last install replaced.
#   --push                               With --update or --schedule: after a
#                                        successful update, commit and push the
#                                        refreshed patch from this folder's git repo.
#   ITERM_SRC=~/code/iTerm2 bash build-iterm2-hdr.sh   (use another checkout dir)
#
# The patch file must sit next to this script. Safe to re-run after a failure:
# each stage remembers when it has finished.
#
# Installing never replaces the app while it is running. If iTerm2 HDR is open,
# the new build waits and is swapped in as soon as you quit it. The build it
# replaces is kept for --rollback.
#
# Updating replays the patch on the newest iTerm2 with git. If iTerm2 changed
# the same lines the patch does, the update stops, the checkout is put back the
# way it was, and the installed app is left alone. The scheduled job does the
# same and tells you with a notification; its log is
# ~/Library/Logs/iterm2-hdr-update.log.
#
# On older SDKs, temporarily adapt the Foundation Models calls for the
# installed API. Without token counting, AI tab titles use their existing
# prompt-length estimate. Keep warnings nonfatal on older compilers.
#
# Stages:
#   1. Check Xcode.
#   2. Clone iTerm2 and apply the patch (once). With --update, move the patch
#      onto the newest iTerm2.
#   3. iTerm2's one-time toolchain setup, `make setup` (interactive).
#   4. Build the native dependencies, once per Xcode version and again when an
#      update changes them. Same as `make paranoid-deps`, minus the step that
#      regenerates the SF Symbols list: it crashes on some SF Symbols app
#      versions, and its output is already committed to the repo, so the
#      committed copy is used.
#   5. Build iTerm2 (optimized) and install it.
#
# After the first build:
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
SCRIPT_PATH="$SCRIPT_DIR/$(basename "$0")"
PATCH="$SCRIPT_DIR/iterm2-hdr-text.patch"
BASE_FILE="$SCRIPT_DIR/base-commit"
SRC="${ITERM_SRC:-$HOME/src/iTerm2-hdr}"
# The iTerm2 commit the patch is known to apply to, used when it does not apply
# to the newest one. --update rewrites the base-commit file whenever it
# refreshes the patch; the value here is for a copy of the script without it.
BASE_COMMIT=b3010f0d41a1ee9b0bebbc751b1342d428616cc2
if [ -s "$BASE_FILE" ]; then
    BASE_COMMIT="$(tr -d '[:space:]' < "$BASE_FILE")"
fi
DEST="$HOME/Applications/iTerm2 HDR.app"
# A finished build waits here until it can be swapped in, and the build it
# replaces is kept next to it. Both are on the same volume as DEST, so the swap
# is two renames.
STAGED="$SRC/tmp/staged/iTerm2 HDR.app"
PREVIOUS="$SRC/tmp/previous/iTerm2 HDR.app"
SHIM_FILE="$SRC/sources/AITerm/AppleIntelligenceRunner.swift"
SHIM_MARKER="Local build shim added by build-iterm2-hdr.sh"
# Files the HDR text patch touches, for the warning report in compatibility mode.
PATCHED_FILES='iTermCursor|iTermTextDrawingHelper|iTermMetalPerFrameState|iTermTextRenderer|iTermShaderTypes|iTermText\.metal|iTermMetalDriver|PTYSession|SessionView|PTYTextView|ProfilesColorsPreferencesViewController|iTermProfilePreferences|iTermAdvancedSettingsModel|iTermRecordingProfileSanitizer'
# Tracked files the build itself rewrites (iTerm2 commits its built frameworks
# and libraries). Local changes limited to these are build products, not edits.
BUILD_OUTPUTS='(\.framework(\.dSYM)?/|^ThirdParty/|^pwmplugin/binaries/|^xcstrings/)'

SETUP_MARKER="$SRC/.git/hdr-text-setup-done"
DEPS_MARKER="$SRC/.git/hdr-text-deps-xcode"
BUILT_MARKER="$SRC/.git/hdr-text-built-commit"
ATTEMPT_MARKER="$SRC/.git/hdr-text-last-update"
WAITER_PID="$SRC/.git/hdr-text-waiter.pid"
LOCK="$SRC/.git/hdr-text-lock"

LABEL="local.iterm2-hdr-update"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UPDATE_LOG="$HOME/Library/Logs/iterm2-hdr-update.log"
# The scheduled job runs from its own copy of this folder. macOS does not let
# background jobs read Documents, Desktop or Downloads, which is where a clone
# of this repository often lives.
JOB_DIR="$HOME/Library/Application Support/iterm2-hdr-update"
# The scheduled job runs every day but only updates this often.
UPDATE_DAYS="${HDR_UPDATE_DAYS:-7}"
# How long the scheduled job waits for you to quit iTerm2 HDR before giving up
# until its next run.
WAIT_SECONDS=72000

MODE=build
PUSH=0
NOTIFY=0
HAVE_LOCK=0
SHIM_APPLIED=0
FAILED_LOUDLY=0

step() { printf '\n==> %s\n' "$*"; }

usage() { sed -n '2,/^$/p' "$0" | sed -e 's/^#$//' -e 's/^# //'; }

for arg in "$@"; do
    case "$arg" in
        --update) MODE=update ;;
        --auto) MODE=auto; NOTIFY=1 ;;
        --install-on-quit) MODE=waiter; NOTIFY=1 ;;
        --rollback) MODE=rollback ;;
        --schedule) MODE=schedule ;;
        --unschedule) MODE=unschedule ;;
        --push) PUSH=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $arg (try --help)" >&2; exit 2 ;;
    esac
done

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

# Prints a message, and for the background modes also posts it as a notification.
notify() {
    echo "$*"
    if [ "$NOTIFY" = 1 ]; then
        /usr/bin/osascript - "iTerm2 HDR" "$*" >/dev/null 2>&1 <<'EOF' || true
on run argv
    display notification (item 2 of argv) with title (item 1 of argv)
end run
EOF
    fi
}

fail() {
    FAILED_LOUDLY=1
    if [ "$NOTIFY" = 1 ]; then
        notify "$*"
    else
        echo "$*" >&2
    fi
    exit 1
}

app_running() {
    # -a: pgrep leaves out its own ancestors by default, and when this script is
    # run from a tab in iTerm2 HDR, the app is one of them.
    pgrep -a -f "^$DEST/Contents/MacOS/iTerm2" >/dev/null 2>&1
}

# Waits until iTerm2 HDR is not running. $1 is the longest to wait in seconds.
wait_for_quit() {
    local waited=0
    while :; do
        if ! app_running; then
            # Make sure it is really gone and not relaunching.
            sleep 3
            if ! app_running; then
                return 0
            fi
        fi
        if [ "$waited" -ge "$1" ]; then
            return 1
        fi
        sleep 10
        waited=$((waited + 10))
    done
}

# Moves the staged build into place and keeps the one it replaces. Only call
# while iTerm2 HDR is not running.
swap_in() {
    mkdir -p "$HOME/Applications"
    if [ -d "$DEST" ]; then
        rm -rf "$(dirname "$PREVIOUS")"
        mkdir -p "$(dirname "$PREVIOUS")"
        mv "$DEST" "$PREVIOUS"
    fi
    mv "$STAGED" "$DEST"
    rm -rf "$(dirname "$STAGED")"
}

# Waits for iTerm2 HDR to quit, then installs the staged build. Does nothing if
# there is no staged build or another copy of this script is already waiting.
install_when_quit() {
    local other
    if [ ! -d "$STAGED" ]; then
        return 0
    fi
    other="$(cat "$WAITER_PID" 2>/dev/null || true)"
    if [ -n "$other" ] && [ "$other" != "$$" ] && kill -0 "$other" 2>/dev/null &&
        ps -o command= -p "$other" 2>/dev/null | grep -q "build-iterm2-hdr"; then
        echo "Another copy of this script (pid $other) is already waiting to install."
        return 0
    fi
    echo "$$" > "$WAITER_PID"
    if wait_for_quit "$1" && [ -d "$STAGED" ] && ! app_running; then
        swap_in
        notify "The new build is installed. Open iTerm2 HDR to use it."
    fi
    rm -f "$WAITER_PID"
}

acquire_lock() {
    local other
    if ! mkdir "$LOCK" 2>/dev/null; then
        other="$(cat "$LOCK/pid" 2>/dev/null || true)"
        if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
            echo "Another build or update is already running (pid $other)."
            if [ "$MODE" = auto ]; then
                exit 0
            fi
            exit 1
        fi
        rm -rf "$LOCK"
        mkdir "$LOCK"
    fi
    echo "$$" > "$LOCK/pid"
    HAVE_LOCK=1
}

release_lock() {
    if [ "$HAVE_LOCK" = 1 ]; then
        rm -rf "$LOCK"
        HAVE_LOCK=0
    fi
}

# Undo the stand-in appended to SHIM_FILE for the build.
remove_shim() {
    # Only remove the appended block. Preserve pre-existing local edits.
    sed -i '' "/^\/\/ ---- $SHIM_MARKER/,$ d" "$SHIM_FILE"
}

cleanup() {
    if [ "$SHIM_APPLIED" = 1 ]; then
        remove_shim
    fi
    release_lock
    if [ "$1" != 0 ] && [ "$MODE" = auto ] && [ "$FAILED_LOUDLY" = 0 ]; then
        notify "The update stopped with an error. Your installed app is unchanged. Log: $UPDATE_LOG"
    fi
}
trap 'cleanup $?' EXIT

# The Xcode project refuses to build unless this file matches your Xcode, which
# is how it knows the native dependencies were built with it. Record it, and
# tell git to ignore the local change so it never ends up in a commit or PR.
stamp_xcode_version() {
    xcodebuild -version > last-xcode-version
    git update-index --skip-worktree last-xcode-version
}

xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

schedule() {
    local push_arg="" origin job_script
    job_script="$JOB_DIR/$(basename "$SCRIPT_PATH")"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -rf "$JOB_DIR"
    mkdir -p "$(dirname "$PLIST")" "$(dirname "$UPDATE_LOG")" "$(dirname "$JOB_DIR")"
    if [ "$PUSH" = 1 ]; then
        # To push, the job needs a repository of its own: a clone of this one's
        # origin, which it pulls before each update.
        push_arg="<string>--push</string>"
        if ! origin="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null)"; then
            fail "--push needs this folder to be a git repository with an origin remote."
        fi
        git clone -q "$origin" "$JOB_DIR"
        if ! cmp -s "$SCRIPT_PATH" "$job_script" ||
            ! cmp -s "$PATCH" "$JOB_DIR/$(basename "$PATCH")"; then
            rm -rf "$JOB_DIR"
            fail "The background job runs what is published at $origin, and that differs from the files here. Commit and push first, then run --schedule --push again."
        fi
    else
        mkdir -p "$JOB_DIR"
        cp "$SCRIPT_PATH" "$PATCH" "$JOB_DIR/"
        if [ -f "$BASE_FILE" ]; then
            cp "$BASE_FILE" "$JOB_DIR/"
        fi
    fi
    # The job gets your current PATH so it finds the same git, cmake and other
    # tools that a build from this terminal does.
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$(xml_escape "$job_script")</string>
        <string>--auto</string>
        $push_arg
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$(xml_escape "$PATH")</string>
        <key>ITERM_SRC</key>
        <string>$(xml_escape "$SRC")</string>
        <key>HDR_UPDATE_DAYS</key>
        <string>$UPDATE_DAYS</string>
    </dict>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>12</integer>
        <key>Minute</key>
        <integer>30</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>$(xml_escape "$UPDATE_LOG")</string>
    <key>StandardErrorPath</key>
    <string>$(xml_escape "$UPDATE_LOG")</string>
    <key>LowPriorityIO</key>
    <true/>
    <key>Nice</key>
    <integer>10</integer>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "Scheduled. Every day at 12:30 a background job checks whether $UPDATE_DAYS days"
    echo "have passed since the last update, and if so updates iTerm2 HDR."
    if [ "$PUSH" = 1 ]; then
        echo "It runs from its own clone of $origin in"
        echo "$JOB_DIR, and pushes the refreshed patch after a successful update."
    else
        echo "It runs from a copy of this script and patch in"
        echo "$JOB_DIR. Run --schedule again after changing either."
    fi
    echo "Log: $UPDATE_LOG"
    echo "Turn it off with: bash \"$SCRIPT_PATH\" --unschedule"
}

unschedule() {
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    rm -rf "$JOB_DIR"
    echo "Background updates are off."
}

rollback() {
    local spare="$SRC/tmp/rollback-swap.app"
    if [ ! -d "$PREVIOUS" ]; then
        fail "There is no earlier build to go back to."
    fi
    if app_running; then
        fail "Quit iTerm2 HDR first, then run --rollback again."
    fi
    rm -rf "$spare"
    if [ -d "$DEST" ]; then
        mv "$DEST" "$spare"
    fi
    mv "$PREVIOUS" "$DEST"
    if [ -d "$spare" ]; then
        mv "$spare" "$PREVIOUS"
    fi
    echo "Rolled back. The build you just replaced is kept, so --rollback again undoes this."
    echo "A later update installs the newest build again."
}

# Moves the hdr-text branch onto the newest iTerm2. Sets SOURCE_CHANGED.
update_source() {
    local base newest dirty stashed=0 before conflicts deps_stale=0
    step "Checking for new iTerm2 commits"
    # Give up on a stalled connection instead of hanging: under 1 KB/s for a minute.
    if ! git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 fetch -q origin; then
        if [ "$MODE" = auto ]; then
            echo "Could not reach GitHub; will try again at the next run."
            release_lock
            install_when_quit "$WAIT_SECONDS"
            exit 0
        fi
        fail "Could not fetch from GitHub."
    fi
    date +%s > "$ATTEMPT_MARKER"
    base="$(git merge-base hdr-text origin/master)"
    newest="$(git rev-parse origin/master)"
    if [ "$base" = "$newest" ]; then
        echo "Already on the newest iTerm2 ($(git rev-parse --short "$newest"))."
        return 0
    fi
    echo "$(git rev-list --count "$base..$newest") new iTerm2 commits."

    # Submodules are brought back in line later, so their state is not an edit.
    dirty="$(git diff --name-only --ignore-submodules=all HEAD | grep -v -E "$BUILD_OUTPUTS" || true)"
    if [ -n "$dirty" ]; then
        fail "The checkout in $SRC has uncommitted edits, so it was not updated. Commit them to the hdr-text branch or discard them: $(echo "$dirty" | tr '\n' ' ')"
    fi

    # The strings catalog is regenerated by every build and changes upstream all
    # the time; drop the local copy so it cannot collide.
    git checkout -q HEAD -- xcstrings 2>/dev/null || true
    # Let git update the Xcode stamp; it is rewritten before building.
    git update-index --no-skip-worktree last-xcode-version
    git checkout -q HEAD -- last-xcode-version
    # The built dependencies are tracked files. Set them aside so git can move
    # the branch, then put them back so they need not be rebuilt.
    if ! git diff --quiet --ignore-submodules=all HEAD; then
        git stash push -q -m "hdr-text build outputs"
        stashed=1
    fi

    before="$(git rev-parse HEAD)"
    if ! git rebase -q origin/master >/dev/null 2>&1; then
        conflicts="$(git diff --name-only --diff-filter=U | tr '\n' ' ')"
        git rebase --abort
        if [ "$stashed" = 1 ]; then
            git stash pop -q
        fi
        stamp_xcode_version
        fail "iTerm2 changed the same lines as the HDR patch, so the update stopped and nothing was changed. The patch needs a manual rebase in $SRC. Conflicts: $conflicts"
    fi
    echo "Patch moved onto iTerm2 $(git rev-parse --short origin/master)."

    # A changed submodule means the native dependencies must be rebuilt.
    if git diff --raw "$before" HEAD | grep -q ' 160000 '; then
        deps_stale=1
    fi
    if [ "$stashed" = 1 ]; then
        if ! git stash pop -q >/dev/null 2>&1; then
            # iTerm2 shipped new copies of the built dependencies. Take theirs
            # as the starting point and rebuild.
            git reset -q --hard HEAD
            git stash drop -q
            deps_stale=1
        fi
    fi
    stamp_xcode_version
    if [ "$deps_stale" = 1 ]; then
        echo "The native dependencies changed and will be rebuilt."
        rm -f "$DEPS_MARKER"
    fi
    SOURCE_CHANGED=1
}

# Rewrites the patch file from the hdr-text branch if the patch itself changed.
# Returns 0 when the file was rewritten.
refresh_patch() {
    local base fresh
    base="$(git merge-base hdr-text origin/master)"
    fresh="$(mktemp)"
    git format-patch --stdout "$base..hdr-text" > "$fresh"
    if [ "$(git patch-id --stable < "$fresh" | cut -d' ' -f1 | sort)" = \
         "$(git patch-id --stable < "$PATCH" | cut -d' ' -f1 | sort)" ]; then
        rm -f "$fresh"
        return 1
    fi
    cat "$fresh" > "$PATCH"
    rm -f "$fresh"
    echo "$base" > "$BASE_FILE"
    echo "Refreshed $(basename "$PATCH") for iTerm2 $(git rev-parse --short "$base")."
    return 0
}

# Commits and pushes the refreshed patch from the folder this script lives in.
# A failure here is reported but does not undo the update.
push_patch() {
    local short
    short="$(git rev-parse --short "$(cat "$BASE_FILE")")"
    if ! git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "$SCRIPT_DIR is not a git repository; not pushing."
        return 0
    fi
    if git -C "$SCRIPT_DIR" add -- "$(basename "$PATCH")" "$(basename "$BASE_FILE")" &&
        git -C "$SCRIPT_DIR" diff --cached --quiet -- "$(basename "$PATCH")" "$(basename "$BASE_FILE")"; then
        return 0
    fi
    if git -C "$SCRIPT_DIR" commit -q -m "Refresh patch for iTerm2 $short" -- \
            "$(basename "$PATCH")" "$(basename "$BASE_FILE")" &&
        git -C "$SCRIPT_DIR" push -q origin HEAD; then
        echo "Pushed the refreshed patch."
    else
        notify "The update worked, but pushing the refreshed patch from $SCRIPT_DIR failed."
    fi
}

# Copies the built app next to the install location and signs it, ready to swap in.
stage_app() {
    local work="$SRC/tmp/staging.tmp"
    rm -rf "$work"
    mkdir -p "$work"
    cp -R "$APP" "$work/iTerm2 HDR.app"
    # The build is unsigned; give it an ad-hoc signature so macOS will launch it.
    codesign --force --deep --sign - "$work/iTerm2 HDR.app"
    codesign --verify --deep --strict "$work/iTerm2 HDR.app"
    rm -rf "$(dirname "$STAGED")"
    mv "$work" "$(dirname "$STAGED")"
}

# --- Modes that do not build -------------------------------------------------
case "$MODE" in
    schedule) schedule; exit 0 ;;
    unschedule) unschedule; exit 0 ;;
    rollback) rollback; exit 0 ;;
    waiter) install_when_quit 2592000; exit 0 ;;
esac

if [ ! -f "$PATCH" ]; then
    fail "Can't find $PATCH. Keep the patch next to this script."
fi

# --- Scheduled run: decide whether there is anything to do -------------------
if [ "$MODE" = auto ]; then
    # Keep the log from growing without bound.
    if [ -f "$UPDATE_LOG" ] && [ "$(wc -c < "$UPDATE_LOG")" -gt 1000000 ]; then
        tail -c 200000 "$UPDATE_LOG" > "$UPDATE_LOG.tmp" && cat "$UPDATE_LOG.tmp" > "$UPDATE_LOG"
        rm -f "$UPDATE_LOG.tmp"
    fi
    echo ""
    echo "---- $(date '+%Y-%m-%d %H:%M') scheduled run ----"
    if [ ! -f "$SETUP_MARKER" ]; then
        fail "Run \"bash $SCRIPT_PATH\" once by hand before background updates can work."
    fi
    last="$(cat "$ATTEMPT_MARKER" 2>/dev/null || echo 0)"
    due=0
    # Half a day of slack so a weekly update lands on the same day each week.
    if [ $(( $(date +%s) - last )) -ge $(( UPDATE_DAYS * 86400 - 43200 )) ]; then
        due=1
    fi
    if [ "$due" = 1 ] && ! pmset -g batt | head -1 | grep -q "AC Power"; then
        echo "On battery; leaving the update for a run on mains power."
        due=0
    fi
    if [ "$due" = 0 ]; then
        echo "No update due."
        install_when_quit "$WAIT_SECONDS"
        exit 0
    fi
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
acquire_lock

# Undo a stand-in left behind if an earlier run was killed mid-build.
if grep -Fq "$SHIM_MARKER" "$SHIM_FILE" 2>/dev/null; then
    remove_shim
fi

SOURCE_CHANGED=0
if git rev-parse -q --verify refs/heads/hdr-text >/dev/null; then
    step "Using existing hdr-text branch"
    git checkout -q hdr-text
    if [ "$MODE" = update ] || [ "$MODE" = auto ]; then
        update_source
    fi
else
    step "Applying the HDR text patch"
    git fetch -q origin
    # Prefer the newest master so you get upstream fixes; fall back to the
    # commit the patch is known to apply to if master has moved too far.
    git checkout -q -b hdr-text origin/master
    if git am -q --3way "$PATCH"; then
        echo "Patch applied on latest master."
    else
        echo "Patch did not apply cleanly on latest master; using $BASE_COMMIT instead."
        git am --abort
        git checkout -q -B hdr-text "$BASE_COMMIT"
        git am -q "$PATCH"
    fi
    date +%s > "$ATTEMPT_MARKER"
    SOURCE_CHANGED=1
fi

if [ "$MODE" = auto ] && [ "$SOURCE_CHANGED" = 0 ] &&
    [ "$(cat "$BUILT_MARKER" 2>/dev/null || true)" = "$(git rev-parse HEAD)" ]; then
    echo "Nothing new to build."
    release_lock
    install_when_quit "$WAIT_SECONDS"
    exit 0
fi

# --- 3. Toolchain setup (once) ----------------------------------------------
if [ ! -f "$SETUP_MARKER" ]; then
    step "One-time toolchain setup (make setup). Answer y to its questions."
    make setup
    touch "$SETUP_MARKER"
fi
# Keep submodules on the commits this branch expects. The dependency build
# leaves its products inside some submodules, and git will not move a submodule
# over them. When that happens the products are stale anyway: discard them and
# rebuild the dependencies.
if ! git submodule update --init --recursive; then
    echo "A submodule changed under its build products; resetting submodules and rebuilding dependencies."
    git submodule update --init --recursive --force
    rm -f "$DEPS_MARKER"
fi

BUILD_DIR="$(xcodebuild -scheme iTerm2 -showBuildSettings 2>/dev/null | awk -F ' = ' '/^ *SYMROOT/ && !found {print $2; found=1}')"

# --- 4. Native dependencies (once per Xcode version, and when they change) ---
if [ ! -f "$DEPS_MARKER" ] || [ "$(cat "$DEPS_MARKER")" != "$XCODE_VERSION" ]; then
    step "Building native dependencies (slow the first time, no downloads needed)"
    # A crashed SF Symbols step can leave its generated files empty; put back
    # the committed versions.
    git checkout -- ThirdParty/SFSymbolEnum
    # Same targets and sandbox as `make paranoid-deps`, without `sfsymbolenum`.
    /usr/bin/sandbox-exec -f deps.sb make BUILD_DIR="$BUILD_DIR" \
        fatlibsixel CoreParse NMSSH bindeps libgit2 sparkle librailroad_dsl pwmadapters
    git checkout -- ThirdParty/SFSymbolEnum
    printf '%s' "$XCODE_VERSION" > "$DEPS_MARKER"
fi
stamp_xcode_version

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
    SHIM_APPLIED=1
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
        fail "The new iTerm2 did not build, so your installed app is unchanged. Build log: $LOG"
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
    fail "Build finished but $APP is missing."
fi
git rev-parse HEAD > "$BUILT_MARKER"

step "Installing"
stage_app

# Only a build that compiled gets published as the new patch.
if [ "$MODE" = update ] || [ "$MODE" = auto ]; then
    if [ "$PUSH" = 1 ] && git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        # Start from what is published, so the push is a fast-forward.
        git -C "$SCRIPT_DIR" pull -q --ff-only ||
            echo "Could not pull in $SCRIPT_DIR; pushing the refreshed patch may be refused."
    fi
    if refresh_patch && [ "$PUSH" = 1 ]; then
        push_patch
    fi
fi

# The rest only waits, so let other runs of this script proceed.
if [ "$SHIM_APPLIED" = 1 ]; then
    remove_shim
    SHIM_APPLIED=0
fi
release_lock

echo ""
if ! app_running; then
    swap_in
    notify "Installed: $DEST"
    echo "Quit your normal iTerm2, then: open \"$DEST\""
elif [ "$MODE" = auto ]; then
    notify "An update is ready. It installs when you quit iTerm2 HDR."
    install_when_quit "$WAIT_SECONDS"
else
    mkdir -p "$(dirname "$UPDATE_LOG")"
    nohup /bin/bash "$SCRIPT_PATH" --install-on-quit >> "$UPDATE_LOG" 2>&1 < /dev/null &
    echo "iTerm2 HDR is running, so the new build is waiting. It installs itself as"
    echo "soon as you quit iTerm2 HDR; open it again afterwards to use the new build."
fi
