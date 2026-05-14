const std = @import("std");
const config = @import("config.zig");
const knn = @import("knn.zig");

pub const K_CLUSTERS: u32 = 1024;
pub const M_PROBE: u32 = 16;
pub const KMEANS_ITERS: u32 = 15;
pub const KMEANS_SEED: u64 = 42;

const Vec16u8 = knn.Vec16u8;

pub const BuildOutput = struct {
    centroids: []align(64) u8,
    offsets: []u32,
    vectors: []align(64) u8,
    labels: []u8,
};

pub fn build(
    allocator: std.mem.Allocator,
    src_vectors: []const u8,
    src_labels: []const u8,
) !BuildOutput {
    const N = config.NUM_REFS;
    const D = config.PADDED_DIMS;
    const K = K_CLUSTERS;

    std.debug.print("IVF build: N={d}, K={d}, iters={d}\n", .{ N, K, KMEANS_ITERS });

    // Allocate outputs.
    var centroids = try allocator.alignedAlloc(u8, .@"64", K * D);
    errdefer allocator.free(centroids);

    var offsets = try allocator.alloc(u32, K + 1);
    errdefer allocator.free(offsets);

    var new_vectors = try allocator.alignedAlloc(u8, .@"64", N * D);
    errdefer allocator.free(new_vectors);

    var new_labels = try allocator.alloc(u8, N);
    errdefer allocator.free(new_labels);

    // Scratch buffers.
    var assignments = try allocator.alloc(u32, N);
    defer allocator.free(assignments);

    var sums = try allocator.alloc(u64, K * D);
    defer allocator.free(sums);

    var counts = try allocator.alloc(u32, K);
    defer allocator.free(counts);

    // 1. Initialize centroids via K-means++.
    //
    //   * pick the first centroid uniformly at random;
    //   * for each subsequent centroid, pick a point with probability
    //     proportional to its squared distance to the nearest already-chosen
    //     centroid (so far points sit, more likely they get picked).
    //
    // Already-chosen centroids have min_dist = 0 by construction (distance to
    // self), so they are never re-picked.
    std.debug.print("  init: k-means++...\n", .{});
    var prng = std.Random.DefaultPrng.init(KMEANS_SEED);
    const rnd = prng.random();

    // min squared distance from each point to its nearest already-chosen centroid.
    var min_dist = try allocator.alloc(u64, N);
    defer allocator.free(min_dist);
    @memset(min_dist, std.math.maxInt(u64));

    // First centroid: uniform random.
    {
        const idx = rnd.intRangeAtMost(usize, 0, N - 1);
        @memcpy(
            centroids[0..D],
            src_vectors[idx * D .. (idx + 1) * D],
        );
    }

    var picked: u32 = 1;
    while (picked < K) : (picked += 1) {
        // Update min_dist with distance to the centroid just placed (index = picked-1).
        const last = picked - 1;
        const new_centroid: Vec16u8 = centroids[last * D ..][0..D].*;

        var total: u64 = 0;
        var i: usize = 0;
        while (i < N) : (i += 1) {
            const ref: Vec16u8 = src_vectors[i * D ..][0..D].*;
            const d: u64 = @intCast(knn.distSquared(ref, new_centroid));
            if (d < min_dist[i]) min_dist[i] = d;
            total += min_dist[i];
        }

        // Sample new centroid with probability proportional to min_dist.
        var sel: usize = N - 1;
        if (total > 0) {
            const r = rnd.uintLessThan(u64, total);
            var cum: u64 = 0;
            i = 0;
            while (i < N) : (i += 1) {
                cum += min_dist[i];
                if (cum > r) {
                    sel = i;
                    break;
                }
            }
        } else {
            // Degenerate: every remaining point coincides with some centroid.
            // Won't happen in practice with N >> K, but be safe.
            sel = rnd.intRangeAtMost(usize, 0, N - 1);
        }

        @memcpy(
            centroids[picked * D .. (picked + 1) * D],
            src_vectors[sel * D .. (sel + 1) * D],
        );
    }

    // 2. K-means iterations.
    var iter: u32 = 0;
    while (iter < KMEANS_ITERS) : (iter += 1) {
        std.debug.print("  iter {d}/{d}...\n", .{ iter + 1, KMEANS_ITERS });

        @memset(counts, 0);
        @memset(sums, 0);

        var i: u32 = 0;
        while (i < N) : (i += 1) {
            const base = @as(usize, i) * D;
            const ref: Vec16u8 = src_vectors[base..][0..D].*;

            // Find nearest centroid.
            var best_d: i32 = std.math.maxInt(i32);
            var best_k: u32 = 0;
            var k: u32 = 0;
            while (k < K) : (k += 1) {
                const cbase = @as(usize, k) * D;
                const cv: Vec16u8 = centroids[cbase..][0..D].*;
                const d = knn.distSquared(ref, cv);
                if (d < best_d) {
                    best_d = d;
                    best_k = k;
                }
            }

            assignments[i] = best_k;
            counts[best_k] += 1;
            const sbase = @as(usize, best_k) * D;
            var j: usize = 0;
            while (j < D) : (j += 1) {
                sums[sbase + j] += src_vectors[base + j];
            }
        }

        // Update centroids = mean of assigned.
        var k: u32 = 0;
        while (k < K) : (k += 1) {
            if (counts[k] == 0) continue;
            const cbase = @as(usize, k) * D;
            const sbase = @as(usize, k) * D;
            const c: u64 = counts[k];
            var j: usize = 0;
            while (j < D) : (j += 1) {
                centroids[cbase + j] = @intCast(sums[sbase + j] / c);
            }
        }

    }

    // 3. Build offsets via cumulative counts.
    offsets[0] = 0;
    var k: u32 = 0;
    while (k < K) : (k += 1) {
        offsets[k + 1] = offsets[k] + counts[k];
    }

    // 4. Reorganize: copy refs into their cluster slots.
    var write_pos = try allocator.alloc(u32, K);
    defer allocator.free(write_pos);
    @memcpy(write_pos, offsets[0..K]);

    var i: u32 = 0;
    while (i < N) : (i += 1) {
        const c = assignments[i];
        const pos = write_pos[c];
        write_pos[c] += 1;

        const src_base = @as(usize, i) * D;
        const dst_base = @as(usize, pos) * D;
        @memcpy(new_vectors[dst_base..][0..D], src_vectors[src_base..][0..D]);
        new_labels[pos] = src_labels[i];
    }

    std.debug.print("IVF build done.\n", .{});

    return .{
        .centroids = centroids,
        .offsets = offsets,
        .vectors = new_vectors,
        .labels = new_labels,
    };
}
