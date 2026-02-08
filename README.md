# kwm - kewuaa's Window Manager

A window manager based on River Wayland Compositor, written in Zig

![tile](./images/tile.png)

![grid](./images/grid.png)

![monocle](./images/monocle.png)

![scroller](./images/scroller.png)

## Requirements

- Zig 0.15
- River Wayland compositor 0.4.x (with river-window-management-v1 protocol)

## Features

**Multiple layout:** tile, grid, monocle, scroller, floating

**Tag:** base tags not workspaces (supports separate window layouts for each tag)

**Rule support:** regex rule match

**Bindings:** bindings in different mode such as default, passthrough orelse your custom mode

**Rich window state:** swallow, maximize, fullscreen, fakefullscreen

**With simple status bar:** dwm like bar

## build

```zig
zig build -Doptimize=ReleaseSafe
```

It will try to find `config.zig` as config file. If not found, will create it from `config.def.zig` as backup.

You can use `-Dconfig` to specify custom config file path, `-Dbar` to enable/disable status bar, default is true, `-Doptimize` to specify build mode.

## configuration

Make your custom modifications in `config.zig`.
(Implementation of support for loading user configurations at runtime already merged to `master` branch)

## usage

Run `kwm` in your river init file or run with `river -c kwm`.

You could see all bindings in `config.zig`. It should be noted that the `quit` action only quit the kwm but not quit river session. It allow you restart kwm directly. If you want to quit river session, try to use `Ctrl+Alt+Delete`.

You could remap keyboard keys(e.g. swap CapsLock with Escape) by setting the XKB layout rules before starting river:
```sh
export XKB_DEFAULT_OPTIONS=caps:swapescape,altwin:swap_alt_win
```
For all options available see `man 7 xkeyboard-config`

## Thanks to these reference project

- https://github.com/riverwm/river - River Wayland compositor
- https://github.com/pinpox/river-pwm - River based window manager
- https://codeberg.org/machi/machi - River based window manager
- https://codeberg.org/dwl/dwl - dwm for wayland
- https://codeberg.org/dwl/dwl-patches/src/branch/main/patches/swallow/swallow.patch - swallow window patch for dwl
- https://github.com/mnemnion/mvzr - regex support

## License

The source code in this project is released under the [GPL-3.0](./LICENSE)
