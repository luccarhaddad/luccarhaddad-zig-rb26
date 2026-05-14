const std = @import("std");
const config = @import("config.zig");
const ivf = @import("ivf.zig");

pub const Dataset = struct {
    vectors: []align(64) u8,
    labels: []u8,
    centroids: []align(64) u8,
    offsets: []u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Dataset) void {
        self.allocator.free(self.vectors);
        self.allocator.free(self.labels);
        self.allocator.free(self.centroids);
        self.allocator.free(self.offsets);
    }

    pub fn quantize(v: f64) u8 {
        if (v < 0) return 0;
        const clamped = if (v > 1.0) 1.0 else v;
        const scaled: f64 = clamped * 254.0 + 1.0;
        return @intFromFloat(@round(scaled));
    }
};

fn setRefRaw(vectors: []u8, labels: []u8, i: usize, vec_f64: []const f64, label_str: []const u8) void {
    const base = i * config.PADDED_DIMS;
    for (vec_f64, 0..) |v, j| {
        vectors[base + j] = Dataset.quantize(v);
    }
    labels[i] = if (std.mem.eql(u8, label_str, "fraud"))
        config.FRAUD
    else
        config.LEGIT;
}

fn decompressGzip(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    var file = try cwd.openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);

    var file_buf: [64 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    var decompress: std.compress.flate.Decompress = .init(
        &file_reader.interface,
        .gzip,
        &.{},
    );

    _ = try decompress.reader.streamRemaining(&out.writer);
    return try out.toOwnedSlice();
}

fn parseJsonInto(allocator: std.mem.Allocator, json_bytes: []const u8, vectors: []u8, labels: []u8) !void {
    var scanner = std.json.Scanner.initCompleteInput(allocator, json_bytes);
    defer scanner.deinit();

    if (try scanner.next() != .array_begin) return error.ExpectedArray;

    var ref_idx: usize = 0;
    var vec_buf: [config.DIMS]f64 = undefined;

    while (true) {
        const token = try scanner.next();
        switch (token) {
            .array_end => break,
            .object_begin => {},
            else => return error.UnexpectedToken,
        }

        var have_vector = false;
        var label_buf: [16]u8 = undefined;
        var label_len: usize = 0;

        while (true) {
            const k = try scanner.next();
            switch (k) {
                .object_end => break,
                .string => |s| {
                    if (std.mem.eql(u8, s, "vector")) {
                        if (try scanner.next() != .array_begin) return error.ExpectedVectorArray;
                        var d: usize = 0;
                        while (d < config.DIMS) : (d += 1) {
                            const num_tok = try scanner.next();
                            const num_str = switch (num_tok) {
                                .number => |n| n,
                                else => return error.ExpectedNumber,
                            };
                            vec_buf[d] = try std.fmt.parseFloat(f64, num_str);
                        }
                        if (try scanner.next() != .array_end) return error.ExpectedArrayEnd;
                        have_vector = true;
                    } else if (std.mem.eql(u8, s, "label")) {
                        const lt = try scanner.next();
                        const ls = switch (lt) {
                            .string => |st| st,
                            else => return error.ExpectedString,
                        };
                        label_len = ls.len;
                        @memcpy(label_buf[0..ls.len], ls);
                    } else {
                        try scanner.skipValue();
                    }
                },
                else => return error.UnexpectedToken,
            }
        }

        if (!have_vector) return error.MissingVector;
        setRefRaw(vectors, labels, ref_idx, &vec_buf, label_buf[0..label_len]);
        ref_idx += 1;
    }
}

/// Reads the JSON source, builds IVF, and writes the .bin file.
/// Used by the `--gen-bin` mode (offline).
pub fn genBin(
    io: std.Io,
    allocator: std.mem.Allocator,
    source_path: []const u8,
    out_path: []const u8,
) !void {
    // 1. Allocate raw vectors+labels (pre-clustering).
    const raw_vectors = try allocator.alignedAlloc(u8, .@"64", config.VECTORS_BYTES);
    defer allocator.free(raw_vectors);
    const raw_labels = try allocator.alloc(u8, config.LABELS_BYTES);
    defer allocator.free(raw_labels);
    @memset(raw_vectors, 0);
    @memset(raw_labels, 0);

    // 2. Decompress + parse JSON (arena freed before IVF build to reclaim memory).
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const temp = arena.allocator();

        std.debug.print("Decompressing {s}...\n", .{source_path});
        const json_bytes = try decompressGzip(io, temp, source_path);
        std.debug.print("Parsing JSON ({d} bytes)...\n", .{json_bytes.len});
        try parseJsonInto(temp, json_bytes, raw_vectors, raw_labels);
    }

    // 3. Build IVF (clusters + reorganizes).
    const out = try ivf.build(allocator, raw_vectors, raw_labels);
    defer {
        allocator.free(out.centroids);
        allocator.free(out.offsets);
        allocator.free(out.vectors);
        allocator.free(out.labels);
    }

    // 4. Write everything to .bin.
    var file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
    defer file.close(io);

    var write_buf: [64 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &write_buf);
    const w: *std.Io.Writer = &file_writer.interface;

    try w.writeAll(out.vectors);
    try w.writeAll(out.labels);
    try w.writeAll(out.centroids);
    try w.writeAll(std.mem.sliceAsBytes(out.offsets));
    try w.flush();

    std.debug.print("Wrote {s}\n", .{out_path});
}

/// Loads a fully built .bin (with IVF data).
pub fn loadFromBin(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Dataset {
    const vectors = try allocator.alignedAlloc(u8, .@"64", config.VECTORS_BYTES);
    errdefer allocator.free(vectors);

    const labels = try allocator.alloc(u8, config.LABELS_BYTES);
    errdefer allocator.free(labels);

    const centroids = try allocator.alignedAlloc(u8, .@"64", ivf.K_CLUSTERS * config.PADDED_DIMS);
    errdefer allocator.free(centroids);

    const offsets = try allocator.alloc(u32, ivf.K_CLUSTERS + 1);
    errdefer allocator.free(offsets);

    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);

    var read_buf: [64 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    const r: *std.Io.Reader = &file_reader.interface;

    try r.readSliceAll(vectors);
    try r.readSliceAll(labels);
    try r.readSliceAll(centroids);
    try r.readSliceAll(std.mem.sliceAsBytes(offsets));

    return .{
        .vectors = vectors,
        .labels = labels,
        .centroids = centroids,
        .offsets = offsets,
        .allocator = allocator,
    };
}
