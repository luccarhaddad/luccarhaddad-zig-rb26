const std = @import("std");
const httpz = @import("httpz");
const config = @import("config.zig");
const dataset_mod = @import("dataset.zig");
const knn = @import("knn.zig");
const query_mod = @import("query.zig");

pub const PORT: u16 = 8080;

pub const App = struct {
    dataset: *const dataset_mod.Dataset,
};

pub fn serve(
    io: std.Io,
    allocator: std.mem.Allocator,
    dataset: *const dataset_mod.Dataset,
) !void {
    var app = App{ .dataset = dataset };

    var server = try httpz.Server(*App).init(io, allocator, .{
        .address = .all(PORT),
        .workers = .{
            .count = 1,
            .max_conn = 1024,
            .min_conn = 32,
            .large_buffer_count = 4,
            .large_buffer_size = 16 * 1024,
            .retain_allocated_bytes = 4096,
        },
        .thread_pool = .{
            .count = 1,
            .buffer_size = 16 * 1024,
            .backlog = 512,
        },
        .request = .{
            .max_body_size = 32 * 1024,
            .buffer_size = 8 * 1024,
        },
    }, &app);
    defer {
        server.stop();
        server.deinit();
    }

    var router = try server.router(.{});
    router.get("/ready", ready, .{});
    router.post("/fraud-score", fraudScore, .{});

    try server.listen();
}

fn ready(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.status = 200;
}

fn fraudScore(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const body = req.body() orelse {
        res.status = 400;
        return;
    };

    var vec_f64: [config.DIMS]f64 = undefined;
    query_mod.parseQuery(req.arena, body, &vec_f64) catch {
        @memset(&vec_f64, 0);
    };

    const query = knn.quantizeQuery(&vec_f64);
    const score = knn.classify(app.dataset, query);
    const approved = score < knn.FRAUD_THRESHOLD;

    res.status = 200;
    try res.json(.{
        .approved = approved,
        .fraud_score = score,
    }, .{});
}
