// SPDX-FileCopyrightText: © 2026 kewuaa
// SPDX-License-Identifier: GPL-3.0-or-later

KWM(1) "kwm" "kewuaa's window manager"

# NAME

kwm - kewuaa's window manager for River Wayland compositor

# SYNOPSIS

*kwm* [_OPTIONS_]++
*river* -c kwm

# DESCRIPTION

_River_ is a non-monolithic Wayland compositor, it does not combine the compositor
and window manager into one program.

kwm is a DWM-like dynamic tiling window manager implementing the
river-window-management-v1 protocol.

See the default configuration file for detailed features.

# OPTIONS

*-h,-help*
	Print a help message and exit.

*-v,-version*
	Print the version number and exit.

*-c,-config*
	Specify custom configuration file path.


# KEYBINDINGS

kwm supports separate keybindings for each mode. Modes can be customized in the
configuration file.

## default mode
Mod4-Shift-r
	Reload the runtime user configuration.

Mod4-Shift-Escape
	Switch to the passthrough mode.

Mod4-Ctrl-f
	Switch to the floating mode.

Mod4-Shift-q
	Quit the river session.

Mod4-Shift-c
	Close the window.

Mod4-Return
	Move the window on top of the stack or swap with the previous master window.

Mod4-Ctrl-\[hl\]
	Focus the master window from anywhere on the stack or return to the
	previous window.

Mod4-b
	Toggle the status bar.

Mod4-\[jk\]
	Focus the next/previous window.

Mod4-Ctrl-\[jk\]
	Focus the next/previous non-floating window.

Mod4-Shift-\[jk\]
	Swap with the next/previous non-floating window in the stack.

Mod4-\[.,\]
	Focus the next/previous output.

Mod4-Shift-\[.,\]
	Send window to the next/previous output.

Mod4-Shift-m
	Toggle fake fullscreen on the window.

Mod4-Shift-f
	Toggle fullscreen on the window.

Mod4-Shift-e
	Toggle maximize on the window.

Mod4-space
	Switch to the previous layout.

Mod4-f
	Toggle floating on the window.

Mod4-Ctrl-s
	Toggle sticky on the window.

Mod4-a
	Toggle swallow on the window.

Mod1-Mod4-f
	Switch to the floating layout.

Mod4-t
	Switch to the tile layout.

Mod4-g
	Switch to the grid layout.

Mod4-d
	Switch to the deck layout.

Mod4-m
	Switch to the monocle layout.

Mod4-s
	Switch to the scroller layout.

Mod4-u
	Switch to the centered master layout.

Mod4-Tab
	Switch to the previous tag.

Mod4-\[';\]
	Shift output's each tag to the next/previous occupied output tag.

Mod4-Shift-\[';\]
	Shift window's each tag to the next/previous unoccupied output tag.

Mod4-[1-9]
	Set the output tag.

Mod4-0
	Set all output tags as active.

Mod4-Ctrl-[1-9]
	Toggle the output tag.

Mod4-Shift-[1-9]
	Set the window tag.

Mod4-Shift-0
	Set the window with all tags.

Mod4-Ctrl-Shift-[1-9]
	Toggle the window tag.

Mod4-\[hl\]
	Decrease/increase the master area size.

Mod1-Mod4-\[hjkl\]
	Set tile layout's master location to left/bottom/top/right.

Mod4-\[-=\]
	Decrease/increase the number of windows in master area.

Mod1-Mod4-\[-=\]
	Decrease/increase the gaps.

Mod4-Shift-a
	Toggle auto swallow.

Mod4-Shift-g
	Toggle grid layout's direction.

Mod4-Shift-u
	Toggle centered master layout's direction.

Mod4-p
	Spawn _wmenu-run_.

Mod4-Shift-Return
	Spawn _foot_.

## passthrough mode

Mod4-Shift-Escape
	Switch to the default mode.

## floating mode

Press any unbound keys will automatically switch to the default mode.

\[hjkl\]
	Move the floating window in the left/down/up/right direction by 10
	pixels.

Mod4-Ctrl-\[hl\]
	Decrease/increase the floating window width by 10 pixels.

Mod4-Ctrl-\[jk\]
	Increase/decrease the floating window height by 10 pixels.

Mod4-Shift-\[hjkl\]
	Snap the floating window to the left/bottom/top/right edge on the
	output.

## status bar

Button1
	Click on a tag label to set the output tag.++
	Click on layout label to switch to the previous layout.++
	Click on mode label to switch to the default mode.++
	Click on title label to move the window on top of the stack.

Button2
	Click on a tag to toggle the window tag.++
	Click on status to spawn _foot(1)_.

Button3
	Click on a tag to toggle the output tag.

## mouse keybindings

Mod4-Button1
	Move the window while dragging.

Mod4-Button3
	Resize the window while dragging.

# CONFIGURATION

kwm supports both compile-time and runtime configuration.

Default configuration is usually installed to one of the following paths:

	/usr/share/doc/kwm/config.zon

	/usr/local/share/doc/kwm/config.zon

Below are some examples on configurable settings:

- *Startup commands*++
Commands to run when starting kwm.

- *Bar*++
Change bar position and fonts.++
Choose status among static text, stdin, and fifo.

- *Input devices* ++
There is an input device manager for _river_ separated from _kwm_ called
_kwim(1)_, implementing the river-input-management-v1 protocol and/or related
protocols in order to configure input devices independent of window manager.
When built with the `-Dkwim` option (defaults to `true`), _kwm_ will call _kwim_
automatically at startup. You can also run _kwim_ to list input devices or apply
a single rule on demand.

- *Keybindings*++
Change keybindings in each mode, and add custom modes.

- *Rules*++
Match windows by app_id or title with regex support.++
Set tag, floating, dimension, decoration, swallow and scroller behaviors.

## Compile Time

Make custom modifications in config.zon (if -Dconfig is not specified).

## Runtime

kwm searches for a user configuration in the following paths:

	$XDG_CONFIG_HOME/kwm/config.zon

	$HOME/.config/kwm/config.zon

The user configuration overrides compile-time configuration. You only need to
specify the values you want to change, rather than duplicating the entire
configuration.

# EXAMPLES

Start kwm with river, inside TTY, Wayland or X:
```
river -c kwm
```

Restart kwm within the current River session:
```
pkill -x kwm
nohup kwm >/dev/null &
```

Start kwm reading status from stdin (need user configuration):
```
river -c 'while :; do date; sleep 1; done | kwm'
```

# SEE ALSO

_river_(1), _kwim(1)_, _kwim(5)_

kwim:
```
https://github.com/kewuaa/kwim
```

Useful software:
```
https://codeberg.org/river/wiki/src/branch/main/pages/useful-software.md
```

# BUGS

https://github.com/kewuaa/kwm/issues
