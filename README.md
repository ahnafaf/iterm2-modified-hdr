# iTerm2 HDR text

A patch for [iTerm2](https://github.com/gnachman/iTerm2) that draws the text in
the focused pane brighter than white on an HDR display, plus a script that
builds a patched copy and installs it next to your normal iTerm2.

It builds on iTerm2's HDR cursor. Brightness is a multiple of normal white
(1.5x to 8x, default 3x), applied in linear light, so colours keep their hue.

## Build

You need a Mac with an HDR display and Xcode 26 or newer.

```sh
git clone https://github.com/ahnafaf/iterm2-modified-hdr.git
cd iterm2-modified-hdr
bash build-iterm2-hdr.sh
```

The script clones iTerm2 into `~/src/iTerm2-hdr`, applies
`iterm2-hdr-text.patch`, builds an optimized app (10 to 20 minutes the first
time) and installs it as `~/Applications/iTerm2 HDR.app`. It is safe to re-run
after a failure. Set `ITERM_SRC` to use a different checkout directory.

## Turn it on

1. Quit your normal iTerm2, then open `~/Applications/iTerm2 HDR.app`. Both
   copies share one bundle ID, so they would fight over settings.
2. Settings > Profiles > Colors: tick **HDR text in focused pane** and pick a
   brightness. With "Use separate colors for light and dark mode" on, the
   setting is per mode.
3. Settings > General > Magic: untick "Disable GPU rendering when disconnected
   from power" if you want HDR text on battery.
4. Settings > General: turn off automatic update checks, or Sparkle may replace
   this build with a stock release.

## When text is boosted

All of these have to be true:

- The profile has HDR text on for the current light or dark mode.
- The pane is the active one in the key window. Other panes, and every pane
  while another window such as Settings has focus, draw normally.
- The profile's background colour is dark.
- The GPU renderer is in use.
- The display has HDR headroom.
- Night Shift is off. To keep HDR text on during Night Shift, search
  "Night Shift" in Settings > Advanced.

The cursor cell and emoji are not boosted.

## License

The patch is a modification of iTerm2 and is distributed under iTerm2's
license. See the iTerm2 repository for the terms.
