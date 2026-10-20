const Self = @This();

pub const Type = enum {
    tile,
    grid,
    monocle,
    deck,
    scroller,
    centered_master,
    float,

    pub fn next(self: Type) Type {
        return switch(self) {
            Type.tile => Type.grid,
            Type.grid => Type.monocle,
            Type.monocle => Type.deck,
            Type.deck => Type.scroller,
            Type.scroller => Type.centered_master,
            Type.centered_master => Type.float,
            Type.float => Type.tile,
        };
    }

    pub fn previous(self: Type) Type {
        return switch(self) {
            Type.tile => Type.float,
            Type.grid => Type.tile,
            Type.monocle => Type.grid,
            Type.deck => Type.monocle,
            Type.scroller => Type.deck,
            Type.centered_master => Type.scroller,
            Type.float => Type.centered_master,
        };
    }
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
