<div align="center">
    <img alt="kwm" src="./logo/kwm.svg" width="256">
</div>

# kwm - kewuaa's Window Manager

[River] is a non-monolithic Wayland compositor, it does not combine the
compositor and window manager into one program.

kwm is a DWM-like dynamic tiling window manager implementing the
river-window-management-v1 protocol.

# Screenshots

![tile](./images/tile.png)

![grid](./images/grid.png)

![monocle](./images/monocle.png)

![scroller](./images/scroller.png)

## Features

- **Layouts:** tile, grid, monocle, deck, scroller, centered master, and
  floating, with per-tag states

- **Tags:** organize windows with tags instead of workspaces, with shift-tags
support

- **Rules:** regex pattern matching for window rules

- **Modes:** separate keybindings for each mode (default, lock, passthrough,
custom)

- **Window States:** swallow, maximize, fullscreen, fake fullscreen, floating,
sticky

- **Autostart:** run commands on startup

- **Status Bar:** dwm-like bar, supporting static text, stdin, and fifo, with
  customized colors

- **Configuration:** support both compile-time and runtime configuration,
  reloading on the fly

See the default [configuration](./config.def.zon) file for detailed features.

## Dependencies

- wayland (libwayland-client)
- xkbcommon
- pixman (if bar enabled)
- fcft (if bar enabled)
- wayland-protocols (compile only)

## Build

Requires zig 0.16.x.

```
zig build -Doptimize=ReleaseSafe
```

- `-Dllvm`: force using LLVM compiler and linker
- `-Dconfig`: specify the default config file path (defaults to `config.zon`,
  copied from `config.def.zon` if missing)
- `-Dbackground`: enable or disable the solid background (defaults to `false`)
- `-Dbar`: enable or disable the status bar (defaults to `true`)
- `-Dkwim`: if to call [kwim] automatically (defaults to `true`)

## Installation

<a href="https://repology.org/project/kwm-window-manager/versions">
  <img align="right" width="192" src="https://repology.org/badge/vertical-allrepos/kwm-window-manager.svg">
</a>

See [packages.md] for community maintained packages.

```sh
zig build install -Doptimize=ReleaseSafe
```

- `--prefix`: specify the path to install files

## Configuration

### Compile Time

Make custom modifications in `config.zon` (if `-Dconfig` is not specified).

### Runtime

`kwm` searches for a user configuration in the following paths:
- `$XDG_CONFIG_HOME/kwm/config.zon`
- `$HOME/.config/kwm/config.zon`

The user configuration overrides compile-time configuration. You only need to
specify the values you want to change, rather than duplicating the entire
configuration.

User configuration can be reloaded on the fly with
<kbd>mod4</kbd>+<kbd>shift</kbd>+<kbd>r</kbd>.

## Configuration Preprocessing

Before loading the configuration, `kwm` can pre-process it by evaluating the
conditions, which allows per-host configuration.

Syntax:

```zig
// @include(file)
// @if(condition)
// @elif(condition)
// @else
// @endif
```

*Conditions* (separated by `,`):

- hostname=HOSTNAME
- env:KEY=VALUE
- env_contains:KEY

## Usage

Run `kwm` in your river init file, or start it with `river -c kwm`.

See `kwm(1)` man page for complete documentation.

See [Useful Software] in river wiki for compatible software.

### Keybindings

See [keybindings] or `KEYBINDINGS` section in `kwm(1)` man page for default
keybindings.

### Keymaps

Keyboard mapping can be customized by setting XKB layout rules before launching
river. For example, to swap <kbd>CapsLock</kbd> with <kbd>Escape</kbd>, and
<kbd>Mod1</kbd> with <kbd>Mod4</kbd>:

```sh
export XKB_DEFAULT_OPTIONS=caps:swapescape,altwin:swap_alt_win
```

See `xkeyboard-config(7)` man page for all options.

### Input Manager

There is an input device manager for river separated from `kwm` called [kwim],
implementing the river-input-management-v1 protocol and/or related protocols in
order to configure input devices independent of window manager.

When built with the `-Dkwim` option (defaults to `true`), `kwm` will call
`kwim` at startup. You can also run `kwim` to list input devices or apply a
single rule on demand.

## Acknowledgments
Thanks to the following reference projects:

- [river] - Wayland compositor
- [river-pwm] - River-based window manager
- [machi] - River-based window manager
- [dwl] - dwm for Wayland
- [swallow patch] - swallow window patch for dwl
- [mvzr] - regex support

## License

The source code of kwm is released under the [GPL-3.0].

The protocols in `protocol/` directory prefixed with river and developed by the
[River] project are released under the ISC license (as stated in their
copyright blocks).

kwm's logo is a recreation based on [River's logo] and released under the
CC-BY-SA-4.0 license.

## Contributing

Contributions are welcome! By contributing to kwm, you agree that your
submitted code will be licensed under [GPL-3.0]. It is the contributors'
responsibility to ensure that all submitted code is either original or
GPL-3.0-compatible.

LLM/"AI" ContributionsContributions **must not** include content generated by large language models or other probabilistictools, including but not limited to Copilot or ChatGPT. This policy covers code, documentation, pullrequests, issues, comments, and any other contributions to the kwm project.
[GPL-3.0]: ./LICENSE
[river]: https://codeberg.org/river/river
[packages.md]: ./doc/packages.md
[Useful Software]: 	https://codeberg.org/river/wiki/src/branch/main/pages/useful-software.md
[keybindings]: ./doc/keybindings.md
[river-pwm]: https://github.com/pinpox/river-pwm
[machi]: https://codeberg.org/machi/machi
[dwl]: https://codeberg.org/dwl/dwl
[swallow patch]: https://codeberg.org/dwl/dwl-patches/src/branch/main/patches/swallow/swallow.patch
[mvzr]: https://github.com/mnemnion/mvzr
[River's logo]: https://codeberg.org/river/river/src/branch/main/logo/logo.svg
[kwim]: https://github.com/kewuaa/kwim
