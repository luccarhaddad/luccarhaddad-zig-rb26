const std = @import("std");
const config = @import("config.zig");
const dataset_mod = @import("dataset.zig");

pub const Vec16u8 = @Vector(config.PADDED_DIMS, u8);
const Vec16i16 = @Vector(config.PADDED_DIMS, i16);
const Vec16i32 = @Vector(config.PADDED_DIMS, i32);
const Vec8i16 = @Vector(8, i16);
const Vec8i32 = @Vector(8, i32);

pub const K_NEIGHBORS = 5;
pub const FRAUD_THRESHOLD = 0.6;

pub inline fn distSquared(a: Vec16u8, b: Vec16u8) i32 {
    const a_wide: Vec16i16 = a;
    const b_wide: Vec16i16 = b;

    const diff = a_wide - b_wide;
    const diff_wide: Vec16i32 = diff;
    const sq = diff_wide * diff_wide;

    return @reduce(.Add, sq);
}

const TopK = struct {
    dists: [K_NEIGHBORS]i32,
    indices: [K_NEIGHBORS]u32,
    filled: usize,

    pub fn init() TopK {
        return .{
            .dists = .{std.math.maxInt(i32)} ** K_NEIGHBORS,
            .indices = .{0} ** K_NEIGHBORS,
            .filled = 0,
        };
    }

    pub inline fn maybeInsert(self: *TopK, d: i32, idx: u32) void {
        if (self.filled == K_NEIGHBORS and d >= self.dists[self.filled - 1]) {
            return;
        }

        var pos: usize = 0;
        while (pos < self.filled and self.dists[pos] < d) : (pos += 1) {}

        var i: usize = if (self.filled < K_NEIGHBORS) self.filled else K_NEIGHBORS - 1;
        while (i < pos) : (i -= 1) {
            self.dists[i] = self.dists[i-1];
            self.indices[i] = self.indices[i-1];
        }

        self.dists[pos] = d;
        self.indices[pos] = idx;

        if (self.filled < K_NEIGHBORS) {
            self.filled += 1;
        }
    }

};

pub fn classify(dataset: *const dataset_mod.Dataset, query: Vec16u8) f32 {
    var topk = TopK.init();

    {
        var i: u32 = 0;
        while (i < K_NEIGHBORS) : (i += 1) {
            const base = @as(usize, i) * config.PADDED_DIMS;
            const ref: Vec16u8 = dataset.vectors[base..][0..config.PADDED_DIMS].*;
            const d = distSquared(query, ref);
            topk.maybeInsert(d, i);
        }
    }

    var i: u32 = K_NEIGHBORS;
    while (i < config.NUM_REFS) : (i += 1) {
        const base = @as(usize, i) * config.PADDED_DIMS;
        const ref: Vec16u8 = dataset.vectors[base..][0..config.PADDED_DIMS].*;
        const threshold: i32 = topk.dists[K_NEIGHBORS - 1];
        const d = distSquaredEarly(query, ref, threshold);
        if (d < threshold) topk.maybeInsert(d, i);
    }

    var fraud_count: u32 = 0;
    for (topk.indices[0..topk.filled]) |idx| {
        if (dataset.labels[idx] == config.FRAUD) fraud_count += 1;
    }

    return @as(f32, @floatFromInt(fraud_count)) / @as(f32, @floatFromInt(K_NEIGHBORS));
}

pub fn quantizeQuery(vec_f64: *const [config.DIMS]f64) Vec16u8 {
    var out: [config.PADDED_DIMS]u8 = .{0} ** config.PADDED_DIMS;
    for (vec_f64, 0..) |val, i| {
        out[i] = dataset_mod.Dataset.quantize(val);
    }
    return out;
}

pub inline fn distSquaredEarly(a: Vec16u8, b: Vec16u8, threshold: i32) i32 {
    const a_wide: Vec16i16 = a;
    const b_wide: Vec16i16 = b;
    const diff = a_wide - b_wide;

    const lo: Vec8i16 = .{ diff[0], diff[1], diff[2], diff[3],
                           diff[4], diff[5], diff[6], diff[7] };
    const hi: Vec8i16 = .{ diff[8], diff[9], diff[10], diff[11],
                           diff[12], diff[13], diff[14], diff[15] };

    const lo_wide: Vec8i32 = lo;
    const sq_lo = lo_wide * lo_wide;
    const partial_lo = @reduce(.Add, sq_lo);

    if (partial_lo >= threshold) return partial_lo;

    const hi_wide: Vec8i32 = hi;
    const sq_hi = hi_wide * hi_wide;
    const partial_hi = @reduce(.Add, sq_hi);

    return partial_lo + partial_hi;
}
