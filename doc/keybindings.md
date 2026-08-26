<!--
SPDX-FileCopyrightText: © 2026 kewuaa
SPDX-License-Identifier: GPL-3.0-or-later
-->

# KEYBINDINGS

kwm supports separate keybindings for each mode. Modes can be customized in the
configuration file.

## Default Mode

| Bindings | Action |
| :--- | :--- |
| Mod4-Shift-r | Reload the runtime user configuration |
| Mod4-Shift-Escape | Switch to the passthrough mode |
| Mod4-Ctrl-f | Switch to the floating mode |
| Mod4-Shift-q | Quit the river session |
| Mod4-Shift-c | Close the window |
| Mod4-Return | Move the window on top of the stack or swap with the previous master window |
| Mod4-Ctrl-\[hl\] | Focus the master window from anywhere on the stack or return to the previous window |
| Mod4-b | Toggle the status bar |
| Mod4-\[jk\] | Focus the next/previous window |
| Mod4-Ctrl-\[jk\] | Focus the next/previous non-floating window |
| Mod4-Shift-\[jk\] | Swap with the next/previous non-floating window in the stack |
| Mod4-\[.,\] | Focus the next/previous output |
| Mod4-Shift-\[.,\] | Send window to the next/previous output |
| Mod4-Shift-m | Toggle fake fullscreen on the window |
| Mod4-Shift-f | Toggle fullscreen on the window |
| Mod4-Shift-e | Toggle maximize on the window |
| Mod4-space | Switch to the previous layout |
| Mod4-f | Toggle floating on the window |
| Mod4-Ctrl-s | Toggle sticky on the window |
| Mod4-a | Toggle swallow on the window |
| Mod1-Mod4-f | Switch to the floating layout |
| Mod4-t | Switch to the tile layout |
| Mod4-g | Switch to the grid layout |
| Mod4-d | Switch to the deck layout |
| Mod4-m | Switch to the monocle layout |
| Mod4-s | Switch to the scroller layout |
| Mod4-u | Switch to the centered master layout |
| Mod4-Tab | Switch to the previous tag |
| Mod4-\[';\] | Shift output's each tag to the next/previous occupied output tag |
| Mod4-Shift-\[';\] | Shift window's each tag to the next/previous unoccupied output tag |
| Mod4-0 | Set all output tags as active |
| Mod4-[1-9] | Set the output tag |
| Mod4-Ctrl-[1-9] | Toggle the output tag |
| Mod4-Shift-[1-9] | Set the window tag |
| Mod4-Ctrl-Shift-[1-9] | Toggle the window tag |
| Mod4-\[hl\] | Decrease/increase the master area size |
| Mod1-Mod4-\[hjkl\] | Set tile layout's master location to left/bottom/top/right |
| Mod4-\[-=\] | Decrease/increase the number of windows in master area |
| Mod1-Mod4-\[-=\] | Decrease/increase the gaps |
| Mod4-Shift-a | Toggle auto swallow |
| Mod4-Shift-g | Toggle grid layout's direction |
| Mod4-Shift-u | Toggle centered master layout's direction |
| Mod4-p | Spawn *wmenu-run* |
| Mod4-Shift-Return | Spawn *foot* |

## Passthrough Mode

| Bindings | Action |
| :--- | :--- |
| Mod4-Shift-Escape | Switch to the default mode |

## Floating Mode

Press any unbound keys will automatically switch to the default mode.

| Bindings | Action |
| :--- | :--- |
| \[hjkl\] | Move the floating window in the left/down/up/right direction by 10 pixels |
| Mod4-Ctrl-\[hl\] | Decrease/increase the floating window width by 10 pixels |
| Mod4-Ctrl-\[jk\] | Increase/decrease the floating window height by 10 pixels |
| Mod4-Shift-\[hjkl\] | Snap the floating window to the left/bottom/top/right edge on the output |

## Status Bar

| Bindings | Action |
| :--- | :--- |
| Button1 | Click on a tag label to set the output tag<br>Click on layout label to switch to the previous layout<br>Click on mode label to switch to the default mode<br>Click on title label to move the window on top of the stack |
| Button2 | Click on a tag to toggle the window tag<br>Click on status to spawn *foot* |
| Button3 | Click on a tag to toggle the output tag |

## Mouse Keybindings

| Bindings | Action |
| :--- | :--- |
| Mod4-Button1 | Move the window while dragging |
| Mod4-Button3 | Resize the window while dragging |
