// SPDX-FileCopyrightText: © 2026 kewuaa
// SPDX-License-Identifier: GPL-3.0-or-later

const Self = @This();

pub const Type = enum {
    tile,
    grid,
    monocle,
    deck,
    scroller,
    centered_master,
    float,
};

pub const Tile = @import("layout/tile.zig");
pub const Grid = @import("layout/grid.zig");
pub const Monocle = @import("layout/monocle.zig");
pub const Deck = @import("layout/deck.zig");
pub const Scroller = @import("layout/scroller.zig");
pub const CenteredMaster = @import("layout/centered_master.zig");


tile: Tile,
grid: Grid,
monocle: Monocle,
deck: Deck,
scroller: Scroller,
centered_master: CenteredMaster,
