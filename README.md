# tegi

Scrollable tiling for macOS. Windows sit in columns on a strip that scrolls sideways, and opening a window never resizes the others. Each display has its own workspaces stacked vertically, with one empty workspace always at the bottom.

```sh
./scripts/app.sh && open .build/tegi.app
```

`tegi.app` asks for Accessibility access (to move windows) and Screen Recording access (for workspace slides and the overview). On first run it writes `~/.config/tegi/config` for your changes and shows the important hotkeys; every default, with what it does, is in `~/.config/tegi/defaults`. Saved changes apply right away, and a broken line keeps the last good config while a banner says which line.

- Windows glide on springs when the strip scrolls, columns move or sizes change, and workspaces slide vertically.
- Option+O, the top-left corner or a four-finger swipe up opens the overview: every workspace, zoomed out. Drag windows between workspaces there.
- Swipe three fingers to scroll the strip or switch workspaces; Option with two fingers or a mouse wheel does the same.
- Option+drag moves a window into a new spot; Option+right-drag resizes it.
- Option+Tab goes back through recent windows.
- `tegi msg action <command>` runs any command, `tegi msg state` prints the layout as JSON, `tegi msg event-stream` prints it on every change, and `tegi validate` checks a config.

## Limits macOS imposes

- Hidden windows keep a sliver visible in a bottom corner, because macOS won't let a window go fully off screen. Quitting or pausing tegi puts them back; after a crash, drag them out.
- Windows don't fade in or out, and nothing is clipped at a display's edge: tegi can't change another app's opacity or clip its window.
- Workspace slides and the overview show pictures of your windows, refreshed every second or so (twice a second in the overview). Live capture would put macOS's screen-sharing indicator in the menu bar.
- Use one macOS Space per display. tegi workspaces replace Spaces.

## Development

```sh
swift build                  # debug build
swift test                   # layout, config and spring tests
./scripts/app.sh run         # build tegi.app, quit the running tegi, start the new one
.build/release/tegi          # run in the terminal to see its output (permissions then go to the terminal)
```

- `Sources/TegiCore` is the layout model, config parser and springs: plain Swift with no macOS window APIs, so it's what the tests cover.
- `Sources/tegi` is the app. `WindowManager/` applies the model to real windows and animates them; `System/` wraps macOS (Accessibility, input, hotkeys, screen capture, the IPC socket); `UI/` is what tegi draws itself (overview and slides, focus ring, switcher, banners).
- `tegi msg event-stream` and `tegi msg state` are the quickest way to see what tegi thinks the layout is.
