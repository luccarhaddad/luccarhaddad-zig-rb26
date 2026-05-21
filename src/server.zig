//! Single-threaded epoll-based HTTP/1.1 server.
//!
//! Why hand-rolled instead of http.zig:
//!   * Phase 3 will swap the TCP listener for a Unix-domain socket that
//!     receives ready-made TCP fds via SCM_RIGHTS. http.zig owns its
//!     listener and doesn't expose a "feed me an fd" entry point.
//!   * Profiling showed the HTTP layer is negligible (<5% of request CPU);
//!     all the win lives in the KNN inner loop. So a minimal server suffices.
//!   * Single-thread epoll is the same model nginx, redis, haproxy and all
//!     high-perf Linux servers use. Worth understanding.
//!
//! Zig 0.16 note: `std.posix` no longer wraps socket/epoll syscalls. We call
//! `std.os.linux.*` directly — these return the raw kernel `usize` value
//! (errno on failure, fd or count on success). The `linux.errno(r)` helper
//! decodes it.

const std = @import("std");
const linux = std.os.linux;
const config = @import("config.zig");
const dataset_mod = @import("dataset.zig");
const knn = @import("knn.zig");
const query_mod = @import("query.zig");

pub const PORT: u16 = 8080;
const MAX_EVENTS = 256;
const MAX_CONNS = 1024;
const READ_BUF_SIZE = 4096;

const RESP_READY: []const u8 =
    "HTTP/1.1 200 OK\r\n" ++
    "Content-Length: 0\r\n" ++
    "Connection: keep-alive\r\n" ++
    "\r\n";

const RESP_NOT_FOUND: []const u8 =
    "HTTP/1.1 404 Not Found\r\n" ++
    "Content-Length: 0\r\n" ++
    "Connection: close\r\n" ++
    "\r\n";

const RESP_BAD_REQUEST: []const u8 =
    "HTTP/1.1 400 Bad Request\r\n" ++
    "Content-Length: 0\r\n" ++
    "Connection: close\r\n" ++
    "\r\n";

pub const App = struct {
    dataset: *const dataset_mod.Dataset,
};

const Conn = struct {
    fd: i32,
    buf: [READ_BUF_SIZE]u8,
    buf_len: usize,
    next_free: i32,
};

const ConnPool = struct {
    conns: [MAX_CONNS]Conn,
    first_free: i32,

    fn init(self: *ConnPool) void {
        for (&self.conns, 0..) |*c, i| {
            c.fd = -1;
            c.buf_len = 0;
            c.next_free = if (i + 1 < MAX_CONNS) @intCast(i + 1) else -1;
        }
        self.first_free = 0;
    }

    fn alloc(self: *ConnPool) ?*Conn {
        if (self.first_free < 0) return null;
        const idx: usize = @intCast(self.first_free);
        const conn = &self.conns[idx];
        self.first_free = conn.next_free;
        conn.next_free = -1;
        return conn;
    }

    fn release(self: *ConnPool, conn: *Conn) void {
        const base = @intFromPtr(&self.conns[0]);
        const idx: i32 = @intCast((@intFromPtr(conn) - base) / @sizeOf(Conn));
        conn.fd = -1;
        conn.buf_len = 0;
        conn.next_free = self.first_free;
        self.first_free = idx;
    }
};

// ─── syscall helpers ─────────────────────────────────────────────────────
// Each raw `linux.*` call returns a `usize`. `linux.errno(r)` decodes it:
// `.SUCCESS` (0) means OK, anything else is the error code.

inline fn must(r: usize, comptime label: []const u8) !usize {
    switch (linux.errno(r)) {
        .SUCCESS => return r,
        else => |e| {
            std.debug.print("{s}: errno={s}\n", .{ label, @tagName(e) });
            return error.SyscallFailed;
        },
    }
}

inline fn closeFd(fd: i32) void {
    _ = linux.close(fd);
}

pub fn serve(
    allocator: std.mem.Allocator,
    dataset: *const dataset_mod.Dataset,
) !void {
    var app = App{ .dataset = dataset };

    const pool = try allocator.create(ConnPool);
    defer allocator.destroy(pool);
    pool.init();

    // ── socket(AF_INET, SOCK_STREAM|NONBLOCK|CLOEXEC, 0) ────────────────
    const listen_fd: i32 = @intCast(try must(
        linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0),
        "socket",
    ));
    defer closeFd(listen_fd);

    // setsockopt(SO_REUSEADDR) — restart without TIME_WAIT.
    const yes: c_int = 1;
    _ = try must(
        linux.setsockopt(listen_fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, @ptrCast(&yes), @sizeOf(c_int)),
        "setsockopt SO_REUSEADDR",
    );

    // bind(listen_fd, 0.0.0.0:PORT) — port is network byte order (big-endian),
    // addr=0 means INADDR_ANY (listen on all interfaces).
    const addr = linux.sockaddr.in{
        .port = std.mem.nativeToBig(u16, PORT),
        .addr = 0,
    };
    _ = try must(
        linux.bind(listen_fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in)),
        "bind",
    );

    _ = try must(linux.listen(listen_fd, 1024), "listen");

    // ── epoll_create1(EPOLL_CLOEXEC) ───────────────────────────────────
    const epoll_fd: i32 = @intCast(try must(
        linux.epoll_create1(linux.EPOLL.CLOEXEC),
        "epoll_create1",
    ));
    defer closeFd(epoll_fd);

    // Register the listen socket. `data.ptr = 0` is our sentinel meaning
    // "this is the listen socket". All Conn pointers are non-zero heap
    // addresses, so no collision possible.
    {
        var ev = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = .{ .ptr = 0 },
        };
        _ = try must(
            linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, listen_fd, &ev),
            "epoll_ctl ADD listen",
        );
    }

    std.debug.print("epoll server listening on :{d}\n", .{PORT});

    // ── event loop ─────────────────────────────────────────────────────
    var events: [MAX_EVENTS]linux.epoll_event = undefined;
    while (true) {
        const r = linux.epoll_wait(epoll_fd, &events, MAX_EVENTS, -1);
        // EINTR (signal interruption) is the only realistic error; just retry.
        const n = switch (linux.errno(r)) {
            .SUCCESS => r,
            .INTR => continue,
            else => |e| {
                std.debug.print("epoll_wait: errno={s}\n", .{@tagName(e)});
                return error.EpollWait;
            },
        };

        for (events[0..n]) |event| {
            if (event.data.ptr == 0) {
                acceptLoop(epoll_fd, listen_fd, pool);
                continue;
            }
            const conn: *Conn = @ptrFromInt(event.data.ptr);

            if (event.events & linux.EPOLL.IN != 0) {
                if (!handleRead(epoll_fd, conn, pool, &app)) continue;
            }
            if (event.events & (linux.EPOLL.HUP | linux.EPOLL.ERR | linux.EPOLL.RDHUP) != 0) {
                closeConn(epoll_fd, conn, pool);
            }
        }
    }
}

/// Drain the accept queue. In level-triggered mode EPOLLIN fires once per
/// wakeup; we must accept() in a loop until EAGAIN to avoid leaving conns
/// waiting in the kernel's queue.
fn acceptLoop(epoll_fd: i32, listen_fd: i32, pool: *ConnPool) void {
    while (true) {
        const r = linux.accept4(listen_fd, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
        switch (linux.errno(r)) {
            .SUCCESS => {},
            .AGAIN => return, // queue empty
            else => |e| {
                std.debug.print("accept4: errno={s}\n", .{@tagName(e)});
                return;
            },
        }
        const client_fd: i32 = @intCast(r);

        // TCP_NODELAY: ship our ~50-byte responses immediately, no Nagle.
        const yes: c_int = 1;
        _ = linux.setsockopt(
            client_fd,
            linux.IPPROTO.TCP,
            linux.TCP.NODELAY,
            @ptrCast(&yes),
            @sizeOf(c_int),
        );

        const conn = pool.alloc() orelse {
            std.debug.print("conn pool exhausted\n", .{});
            closeFd(client_fd);
            continue;
        };
        conn.fd = client_fd;
        conn.buf_len = 0;

        var ev = linux.epoll_event{
            .events = linux.EPOLL.IN | linux.EPOLL.RDHUP,
            .data = .{ .ptr = @intFromPtr(conn) },
        };
        const rc = linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, client_fd, &ev);
        if (linux.errno(rc) != .SUCCESS) {
            std.debug.print("epoll_ctl ADD client: errno\n", .{});
            closeFd(client_fd);
            pool.release(conn);
            continue;
        }
    }
}

/// Drain readable bytes into conn.buf, then process complete requests.
/// Returns false if the connection was closed (caller should skip remaining
/// event flags for this conn).
fn handleRead(epoll_fd: i32, conn: *Conn, pool: *ConnPool, app: *App) bool {
    while (true) {
        if (conn.buf_len >= conn.buf.len) {
            // Headers + body exceeded our 4 KiB cap.
            writeAll(conn.fd, RESP_BAD_REQUEST);
            closeConn(epoll_fd, conn, pool);
            return false;
        }

        const remaining = conn.buf.len - conn.buf_len;
        const r = linux.read(conn.fd, conn.buf[conn.buf_len..].ptr, remaining);
        switch (linux.errno(r)) {
            .SUCCESS => {},
            .AGAIN => break, // kernel buffer empty; wait for next EPOLLIN
            else => {
                closeConn(epoll_fd, conn, pool);
                return false;
            },
        }
        if (r == 0) {
            // Peer closed cleanly.
            closeConn(epoll_fd, conn, pool);
            return false;
        }
        conn.buf_len += r;
    }

    while (true) {
        switch (tryProcess(conn, app)) {
            .need_more => return true,
            .processed => {},
            .close => {
                closeConn(epoll_fd, conn, pool);
                return false;
            },
        }
    }
}

const ProcessResult = enum { need_more, processed, close };

fn tryProcess(conn: *Conn, app: *App) ProcessResult {
    const buf = conn.buf[0..conn.buf_len];

    const headers_end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return .need_more;
    const body_offset = headers_end + 4;
    const headers = buf[0..headers_end];

    const first_line_end = std.mem.indexOfScalar(u8, headers, '\r') orelse return .close;
    const first_line = headers[0..first_line_end];

    var it = std.mem.tokenizeScalar(u8, first_line, ' ');
    const method = it.next() orelse return .close;
    const path = it.next() orelse return .close;

    const content_length = parseContentLength(headers[first_line_end + 2 ..]);

    if (conn.buf_len < body_offset + content_length) return .need_more;
    const body = conn.buf[body_offset .. body_offset + content_length];

    var keep_alive: bool = true;
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/ready")) {
        writeAll(conn.fd, RESP_READY);
    } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/fraud-score")) {
        handleFraudScore(conn.fd, body, app);
    } else {
        writeAll(conn.fd, RESP_NOT_FOUND);
        keep_alive = false;
    }

    // Shift remaining bytes left for pipelined requests.
    const consumed = body_offset + content_length;
    if (consumed < conn.buf_len) {
        std.mem.copyForwards(u8, conn.buf[0 .. conn.buf_len - consumed], conn.buf[consumed..conn.buf_len]);
        conn.buf_len -= consumed;
    } else {
        conn.buf_len = 0;
    }

    return if (keep_alive) .processed else .close;
}

fn parseContentLength(header_bytes: []const u8) usize {
    var it = std.mem.tokenizeAny(u8, header_bytes, "\r\n");
    while (it.next()) |line| {
        if (line.len < 16) continue;
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const value = std.mem.trim(u8, line[15..], " \t");
            return std.fmt.parseInt(usize, value, 10) catch 0;
        }
    }
    return 0;
}

fn handleFraudScore(fd: i32, body: []const u8, app: *App) void {
    var vec_f64: [config.DIMS]f64 = undefined;

    var arena_buf: [16 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    query_mod.parseQuery(fba.allocator(), body, &vec_f64) catch {
        @memset(&vec_f64, 0);
    };

    const query = knn.quantizeQuery(&vec_f64);
    const score = knn.classify(app.dataset, query);
    const approved = score < knn.FRAUD_THRESHOLD;

    var body_buf: [64]u8 = undefined;
    const json_body = std.fmt.bufPrint(&body_buf, "{{\"approved\":{s},\"fraud_score\":{d:.4}}}", .{
        if (approved) "true" else "false",
        score,
    }) catch return;

    var resp_buf: [256]u8 = undefined;
    const response = std.fmt.bufPrint(&resp_buf,
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: keep-alive\r\n" ++
            "\r\n{s}",
        .{ json_body.len, json_body },
    ) catch return;

    writeAll(fd, response);
}

/// Write all bytes, retrying on partial writes. For our tiny responses this
/// almost always completes in one syscall, but we handle the rare partial.
fn writeAll(fd: i32, data: []const u8) void {
    var sent: usize = 0;
    while (sent < data.len) {
        const r = linux.write(fd, data[sent..].ptr, data.len - sent);
        switch (linux.errno(r)) {
            .SUCCESS => sent += r,
            .AGAIN => return, // kernel buffer full; give up (very rare for 50-byte resp)
            else => return,
        }
    }
}

fn closeConn(epoll_fd: i32, conn: *Conn, pool: *ConnPool) void {
    _ = linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_DEL, conn.fd, null);
    closeFd(conn.fd);
    pool.release(conn);
}
