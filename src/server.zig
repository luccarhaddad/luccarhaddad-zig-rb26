const std = @import("std");
const config = @import("config.zig");
const dataset_mod = @import("dataset.zig");
const knn = @import("knn.zig");
const query_mod = @import("query.zig");

const net = std.Io.net;

pub const PORT: u16 = 8080;

const READY_RESPONSE: []const u8 =
    "HTTP/1.1 200 OK\r\n" ++
    "Content-Length: 0\r\n" ++
    "Connection: keep-alive\r\n" ++
    "\r\n";

const NOT_FOUND_RESPONSE: []const u8 =
    "HTTP/1.1 404 Not Found\r\n" ++
    "Content-Length: 0\r\n" ++
    "Connection: keep-alive\r\n" ++
    "\r\n";

const BAD_REQUEST_RESPONSE: []const u8 =
    "HTTP/1.1 400 Bad Request\r\n" ++
    "Content-Length: 0\r\n" ++
    "Connection: close\r\n" ++
    "\r\n";

pub fn serve(
    io: std.Io,
    persistent: std.mem.Allocator,
    dataset: *const dataset_mod.Dataset,
) !void {

    const addr = try net.IpAddress.parse("0.0.0.0", PORT);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.close();

    while (true) {
        const stream = server.accept(io) catch |err| {
            std.debug.print("erro no accept: {}\n", .{err});
            continue;
        };
        handleConnection(io, stream, persistent, dataset) catch |err| {
            std.debug.print("erro na conexão: {}\n", .{err});
        };
    }
}

fn handleConnection(
    io: std.Io,
    stream: net.Stream,
    persistent: std.mem.Allocator,
    dataset: *const dataset_mod.Dataset,
) !void {
    defer stream.close(io);

    var read_buf: [16 * 1024]u8 = undefined;
    var write_buf: [4 * 1024]u8 = undefined;

    var reader_state = stream.reader(io, &read_buf);
    var writer_state = stream.writer(io, &write_buf);
    const reader: *std.Io.Reader = &reader_state.interface;
    const writer: *std.Io.Writer = &writer_state.interface;

    // Loop de requests sobre a mesma conexão TCP (keep-alive).
    while (true) {
        handleOneRequest(reader, writer, persistent, dataset) catch |err| {
            if (err != error.EndOfStream) {
                std.debug.print("erro: {}\n", .{err});
            }
            return;
        };
    }
}

const Method = enum { get, post, other };

const RequestLine = struct {
    method: Method,
    path: []const u8,
};

fn parseRequestLine(line: []const u8) RequestLine {
    // Espera "GET /ready HTTP/1.1" ou similar
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const method_str = it.next() orelse return .{ .method = .other, .path = "" };
    const path = it.next() orelse return .{ .method = .other, .path = "" };

    const method: Method =
        if (std.mem.eql(u8, method_str, "GET"))  .get
        else if (std.mem.eql(u8, method_str, "POST")) .post
        else .other;

    return .{ .method = method, .path = path };
}

fn parseContentLength(headers_block: []const u8) ?usize {
    // Busca case-insensitive por "content-length:"
    var it = std.mem.tokenizeAny(u8, headers_block, "\r\n");
    while (it.next()) |line| {
        if (line.len < 16) continue; // "content-length: " já tem 16
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const value = std.mem.trim(u8, line[15..], " \t");
            return std.fmt.parseInt(usize, value, 10) catch null;
        }
    }
    return null;
}

fn handleOneRequest(
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    persistent: std.mem.Allocator,
    dataset: *const dataset_mod.Dataset,
) !void {
    var headers_buf: [8 * 1024]u8 = undefined;
    const headers_block = try readHeaders(reader, &headers_buf);

    // 2. Parseia a primeira linha pra saber method + path.
    const first_line_end = std.mem.indexOfScalar(u8, headers_block, '\r') orelse {
        return error.MalformedRequest;
    };
    const request_line = parseRequestLine(headers_block[0..first_line_end]);

    // 3. Roteia.
    if (request_line.method == .get and std.mem.eql(u8, request_line.path, "/ready")) {
        try writer.writeAll(READY_RESPONSE);
        try writer.flush();
        return;
    }

    if (request_line.method == .post and std.mem.eql(u8, request_line.path, "/fraud-score")) {
        // Lê o body conforme Content-Length.
        const content_length = parseContentLength(headers_block) orelse {
            try writer.writeAll(BAD_REQUEST_RESPONSE);
            try writer.flush();
            return;
        };

        // Lê o body inteiro num buffer alocado pela arena.
        var arena = std.heap.ArenaAllocator.init(persistent);
        defer arena.deinit();
        const alloc = arena.allocator();

        const body = try alloc.alloc(u8, content_length);
        try reader.readSliceAll(body);

        // Processa.
        var vec_f64: [config.DIMS]f64 = undefined;
        query_mod.parseQuery(alloc, body, &vec_f64) catch {
            // JSON malformado — defaults zerados continuam, classifica mesmo assim.
            @memset(&vec_f64, 0);
        };
        const query = knn.quantizeQuery(&vec_f64);
        const score = knn.classify(dataset, query);
        const approved = score < knn.FRAUD_THRESHOLD;

        // Formata resposta JSON.
        var body_buf: [128]u8 = undefined;
        const json_body = try std.fmt.bufPrint(&body_buf,
            "{{\"approved\":{s},\"fraud_score\":{d:.2}}}",
            .{ if (approved) "true" else "false", score });

        // Headers + body.
        var resp_buf: [256]u8 = undefined;
        const response = try std.fmt.bufPrint(&resp_buf,
            "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: keep-alive\r\n" ++
            "\r\n{s}",
            .{ json_body.len, json_body });

        try writer.writeAll(response);
        try writer.flush();
        return;
    }

    // Rota desconhecida.
    try writer.writeAll(NOT_FOUND_RESPONSE);
    try writer.flush();
}

fn readHeaders(reader: *std.Io.Reader, buf: []u8) ![]const u8 {
    var len: usize = 0;
    while (true) {
        if (len >= buf.len) return error.HeadersTooLarge;
        const byte = try reader.readByte();
        buf[len] = byte;
        len += 1;
        if (len >= 4 and
            buf[len - 4] == '\r' and buf[len - 3] == '\n' and
            buf[len - 2] == '\r' and buf[len - 1] == '\n')
        {
            return buf[0 .. len - 4];
        }
    }
}
