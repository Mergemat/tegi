<p align="center"><img src="Resources/brand/app-icon.png" width="180" alt=""></p>

# tegi

niri's scrollable tiling, on macOS. Columns on a strip that scrolls sideways, workspaces stacked vertically, nothing ever squished. No SIP changes.

<p align="center"><img src="https://github.com/Mergemat/tegi/releases/download/v0.5.0/tegi-demo.gif" alt="Windows tiling on a scrolling strip as they open, a terminal stacking under the editor, a column changing width and maximizing, moving to another workspace, and the overview"></p>

```sh
brew trust mergemat/tap
brew install mergemat/tap/tegi
```

Apple silicon, macOS 14 or later.

| | |
|---|---|
| `mod` + `H` `J` `K` `L` | move focus; add `Shift` to take the window along |
| `mod` + `U` `I` | workspace below, above |
| `mod` + `O` | overview: every workspace, drag windows between them |
| `mod` + `R` · `F` | cycle column widths · maximize the column |
| `mod` + `,` `.` | pull a window into the column · push it back out |
| three fingers | scroll the strip, switch workspaces; four up for the overview |

`mod` is Option, or any combination you pick: Hyper with or without Shift works as Raycast, Hyperkey and Karabiner send it.

- **niri's names:** `center-focused-column`, `preset-column-widths`, `focus-column-left`, `move-column-to-workspace-down` and the rest, one setting per line in `~/.config/tegi/config`. Saved changes apply live.
- **Settings window:** every option, writing that same file.
- **Rules:** per app or title, float or tile, width, workspace, display, focus.
- **Stubborn apps:** a window an app moves on its own goes back in its column. Stacks reserve each window's accepted minimum height; if they cannot fit, moving focus brings that window into view. `reset-window-height` clears the learned height limit.
- **Scripting:** `tegi msg action <command>`, `tegi msg state`, `tegi msg event-stream`. State includes requested and displayed frames in both motion modes.

## Limits macOS imposes

- Standard motion parks off-screen windows with a sliver in a bottom corner. Direct motion clips them completely. Quitting tegi puts them back.
- Standard motion also parks upper windows in a stack taller than the display until focus brings them back into view.
- Standard motion uses snapshots for slides and the overview. Direct motion shows live windows.
- One macOS Space per display: tegi's workspaces replace Spaces.

## Development

```sh
swift build                  # debug build
swift test                   # layout, config, keys and spring tests
./scripts/app.sh run         # build tegi.app, quit the running tegi, start the new one
FAST=1 ./scripts/app.sh run  # the same, rebuilt in seconds but less optimized
.build/release/tegi          # run in the terminal to see its output (permissions then go to the terminal)
./scripts/icon.sh            # compile Resources/AppIcon.icon into the app icon (needs Xcode)
swift scripts/social.swift   # redraw the sharing images, og.png and social.png
```

Direct mode (Settings → Direct mode, or `window-server-motion on`) controls window presentation and clipping through WindowServer transactions and shows windows live in the overview. Apps keep their native size when they refuse a resize; size animation only scales content after the app accepts the target backing size. It needs SIP off and the `-arm64e_preview_abi` boot argument, as yabai does. Live windows ask for your password once, to load a small Dock helper that unloads right after granting tegi access, and to let tegi load that exact helper again without asking (`/Library/PrivilegedHelperTools/tegi-dock-loader` and `/etc/sudoers.d/tegi`, both removed when you turn direct motion off). The grant ends when tegi quits. Until the Dock grants access, or if macOS refuses, windows stay where they are and Settings says why. `tegi msg state` includes commit timings.

- `Sources/TegiCore` is the layout model, config parser and springs: plain Swift with no macOS window APIs, so it's what the tests cover.
- `Sources/tegi` is the app. `WindowManager/` applies the model to real windows and animates them; `System/` wraps macOS (Accessibility, input, hotkeys, screen capture, the IPC socket); `UI/` is what tegi draws itself (overview and slides, focus ring, switcher, cheat sheet, banners) and the Settings and welcome windows.
- `tegi msg event-stream` and `tegi msg state` are the quickest way to see what tegi thinks the layout is.

To investigate trackpad recognition, run `tegi msg input-trace start`, reproduce the unwanted gesture and a deliberate three/four-finger swipe, then run `tegi msg input-trace stop`. The reply shows the local JSONL file path. `tegi msg input-trace status` reports recording state, file size and any error; `tegi msg input-trace delete` stops recording and removes the capture. Recording is off by default, appends across starts, and stops at 64 MiB. It records contact data, callback timestamps, native scroll phases, routing decisions and emitted gestures. Clock values retain their source units; the arrival timestamps provide a shared timeline.

Scroll ownership is conservative: a sequence already delivered to an app stays with that app through its end and momentum, even if another contact lands. While contacts are undecided, the native prefix is buffered for up to 80 ms of scroll-event time. Recognition routes that prefix to tegi; rejection or timeout replays it to the app. Capture traces before tuning that handoff or palm thresholds.

## Releasing

`./scripts/release.sh 1.2.3` builds the app, zips it and renders the cask into `.build/dist`, without publishing anything. Pushing a `v1.2.3` tag runs the same script in CI, publishes the GitHub release and commits the cask to `Mergemat/homebrew-tap` (it needs the `HOMEBREW_TAP_DEPLOY_KEY` secret).

Releases are signed ad hoc with a requirement pinned to the bundle ID, so permissions survive upgrades. With a Developer ID, set `SIGN_IDENTITY` and `NOTARY_PROFILE`: the app is then notarized, the cask no longer needs to clear the quarantine flag, and tegi can go to Homebrew's main cask repository for a plain `brew install tegi`.
