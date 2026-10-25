<p align="center"><img src="Resources/brand/app-icon.png" width="180" alt=""></p>

# tegi

niri's scrollable tiling, on macOS. Windows sit in columns on a strip that scrolls sideways, and opening a window never resizes the others. Each display has its own workspaces stacked vertically, with one empty workspace always at the bottom. No SIP changes, no macOS Spaces.

```sh
brew trust mergemat/tap
brew install mergemat/tap/tegi
```

tegi starts right away and at every login. A welcome window asks for Accessibility (to move windows) and Screen Recording (for workspace slides and the overview). The config is `~/.config/tegi/config`; every default, with what it does, is in `~/.config/tegi/defaults`. Saved changes apply right away, and a broken line keeps the last good config while a banner says which line.

**Coming from niri:** options and actions keep niri's names (`center-focused-column`, `preset-column-widths`, `default-column-display`, `focus-column-left`, `consume-or-expel-window-left`, `move-column-to-workspace-down` and the rest), in a plain line-per-setting file instead of KDL.

- **Your key:** every default shortcut is `mod+…`, and `mod` is Option, Control-Option, Command-Option, or a Hyper key with or without Shift (as Raycast, Hyperkey and Karabiner send it). With mod, H J K L move focus; add Shift to take the window along.
- **Motion:** windows glide on springs when the strip scrolls, columns move or sizes change, and workspaces slide vertically. Every animation's spring is configurable.
- **Overview:** mod+O, a hot corner or a four-finger swipe up zooms out to every workspace. Drag windows between workspaces there. Zoom, spacing, corners, names, app icons and a blurred-wallpaper backdrop are all settings.
- **Gestures:** three fingers scroll the strip or switch workspaces. Hold Option (`swipe-modifier`) and two fingers or a mouse wheel do the same; Option+drag moves a window, Option+right-drag resizes it.
- **Window rules:** per app or title, float or tile, set a width, open on a named workspace or display, open maximized, or don't take focus. New windows open right or left of the focused one, or at either end.
- **Apps that fight back:** a window the app moves or resizes on its own goes back in its column, and one that keeps its own size (video players, fixed-size apps) gets a ring that fits it.
- **mod+Tab:** recent windows on a quiet strip, from everywhere, one display or one workspace.
- **Settings:** a window with every option in it, writing the same plain-text config.
- **Scripting:** `tegi msg action <command>` runs any action, `tegi msg state` prints the layout as JSON, `tegi msg event-stream` prints it on every change, and `tegi validate` checks a config.

## Limits macOS imposes

- Hidden windows keep a sliver visible in a bottom corner, because macOS won't let a window go fully off screen. Quitting or pausing tegi puts them back; after a crash, drag them out.
- Windows don't fade in or out, and nothing is clipped at a display's edge: tegi can't change another app's opacity or clip its window.
- Workspace slides, the overview and the switcher show pictures of your windows, taken as you leave a window and every few seconds while you work (twice a second in the overview). Live capture would put macOS's screen-sharing indicator in the menu bar.
- Use one macOS Space per display. tegi workspaces replace Spaces.

## Development

```sh
swift build                  # debug build
swift test                   # layout, config, keys and spring tests
./scripts/app.sh run         # build tegi.app, quit the running tegi, start the new one
.build/release/tegi          # run in the terminal to see its output (permissions then go to the terminal)
./scripts/icon.sh            # compile Resources/AppIcon.icon into the app icon (needs Xcode)
swift scripts/social.swift   # redraw the sharing images, og.png and social.png
```

- `Sources/TegiCore` is the layout model, config parser and springs: plain Swift with no macOS window APIs, so it's what the tests cover.
- `Sources/tegi` is the app. `WindowManager/` applies the model to real windows and animates them; `System/` wraps macOS (Accessibility, input, hotkeys, screen capture, the IPC socket); `UI/` is what tegi draws itself (overview and slides, focus ring, switcher, cheat sheet, banners) and the Settings and welcome windows.
- `tegi msg event-stream` and `tegi msg state` are the quickest way to see what tegi thinks the layout is.

## Releasing

`./scripts/release.sh 1.2.3` builds the universal app, zips it and renders the cask into `.build/dist`, without publishing anything. Pushing a `v1.2.3` tag runs the same script in CI, publishes the GitHub release and commits the cask to `Mergemat/homebrew-tap` (it needs the `HOMEBREW_TAP_DEPLOY_KEY` secret).

Releases are signed ad hoc with a requirement pinned to the bundle ID, so permissions survive upgrades. With a Developer ID, set `SIGN_IDENTITY` and `NOTARY_PROFILE`: the app is then notarized, the cask no longer needs to clear the quarantine flag, and tegi can go to Homebrew's main cask repository for a plain `brew install tegi`.
