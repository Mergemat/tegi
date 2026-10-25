<p align="center"><img src="Resources/brand/app-icon.png" width="180" alt=""></p>

# tegi

Scrollable tiling for macOS. Windows sit in columns on a strip that scrolls sideways, and opening a window never resizes the others. Each display has its own workspaces stacked vertically, with one empty workspace always at the bottom.

```sh
brew trust mergemat/tap
brew install mergemat/tap/tegi
```

tegi starts right away and at every login. It asks for Accessibility access (to move windows) and Screen Recording access (for workspace slides and the overview). On first run it writes `~/.config/tegi/config` for your changes and shows the important hotkeys; every default, with what it does, is in `~/.config/tegi/defaults`. Saved changes apply right away, and a broken line keeps the last good config while a banner says which line.

- Windows glide on springs when the strip scrolls, columns move or sizes change, and workspaces slide vertically.
- Option+O, the hot corner (top-left unless you pick another) or a four-finger swipe up opens the overview: every workspace, zoomed out. Drag windows between workspaces there.
- Swipe three fingers to scroll the strip or switch workspaces; Option with two fingers or a mouse wheel does the same.
- Option+drag moves a window into a new spot; Option+right-drag resizes it.
- Option+Tab goes back through recent windows.
- Every setting has a place in the Settings window, and the config stays one plain-text file.
- `tegi msg action <command>` runs any command, `tegi msg state` prints the layout as JSON, `tegi msg event-stream` prints it on every change, and `tegi validate` checks a config.

## Limits macOS imposes

- Hidden windows keep a sliver visible in a bottom corner, because macOS won't let a window go fully off screen. Quitting or pausing tegi puts them back; after a crash, drag them out.
- Windows don't fade in or out, and nothing is clipped at a display's edge: tegi can't change another app's opacity or clip its window.
- Workspace slides, the overview and the switcher show pictures of your windows, taken as you leave a window and every few seconds while you work (twice a second in the overview). Live capture would put macOS's screen-sharing indicator in the menu bar.
- Use one macOS Space per display. tegi workspaces replace Spaces.

## Development

```sh
swift build                  # debug build
swift test                   # layout, config and spring tests
./scripts/app.sh run         # build tegi.app, quit the running tegi, start the new one
.build/release/tegi          # run in the terminal to see its output (permissions then go to the terminal)
./scripts/icon.sh            # compile Resources/AppIcon.icon into the app icon (needs Xcode)
swift scripts/social.swift   # redraw the sharing images, og.png and social.png
```

- `Sources/TegiCore` is the layout model, config parser and springs: plain Swift with no macOS window APIs, so it's what the tests cover.
- `Sources/tegi` is the app. `WindowManager/` applies the model to real windows and animates them; `System/` wraps macOS (Accessibility, input, hotkeys, screen capture, the IPC socket); `UI/` is what tegi draws itself (overview and slides, focus ring, switcher, banners).
- `tegi msg event-stream` and `tegi msg state` are the quickest way to see what tegi thinks the layout is.

## Releasing

`./scripts/release.sh 0.1.0` builds the universal app, zips it and renders the cask into `.build/dist`, without publishing anything. Pushing a `v0.1.0` tag runs the same script in CI, publishes the GitHub release and commits the cask to `Mergemat/homebrew-tap` (it needs the `HOMEBREW_TAP_DEPLOY_KEY` secret).

Releases are signed ad hoc with a requirement pinned to the bundle ID, so permissions survive upgrades. With a Developer ID, set `SIGN_IDENTITY` and `NOTARY_PROFILE`: the app is then notarized, the cask no longer needs to clear the quarantine flag, and tegi can go to Homebrew's main cask repository for a plain `brew install tegi`.
