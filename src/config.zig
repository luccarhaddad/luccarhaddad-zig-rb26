pub const NUM_REFS: usize = 3_000_000;
pub const DIMS: usize = 14;
pub const PADDED_DIMS: usize = 16;
pub const VECTORS_BYTES: usize = NUM_REFS * PADDED_DIMS;
pub const LABELS_BYTES: usize = NUM_REFS;
pub const LEGIT: u8 = 0;
pub const FRAUD: u8 = 1;
pub const REFERENCES_PATH: []const u8 = "references.json.gz";
