/// Neutral grid geometry types shared by the core IO layer and the renderer.
///
/// Owning `GridSize` here (rather than under `renderer/`) lets the core IO
/// layer (termio) size the grid without importing the renderer namespace,
/// fixing a layer inversion. `renderer/size.zig` re-exports `GridSize` so
/// existing renderer-side users keep compiling unchanged.
/// Grid dimensions in cells.
pub const GridSize = struct {
    cols: u16 = 80,
    rows: u16 = 24,
};
