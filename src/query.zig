const std = @import("std");
const config = @import("config.zig");

const MAX_AMOUNT: f64 = 10000.0;
const MAX_INSTALLMENTS: f64 = 12;
const AMOUNT_VS_AVG_RATIO: f64 = 10.0;
const MAX_MINUTES: f64 = 1440.0;
const MAX_KM: f64 = 1000.0;
const MAX_TX_COUNT_24H: f64 = 20.0;
const MAX_MERCHANT_AVG_AMOUNT: f64 = 10000.0;

const mcc_risk_table = std.StaticStringMap(f64).initComptime(.{
    .{ "5411", 0.15 }, .{ "5812", 0.30 }, .{ "5912", 0.20 },
    .{ "5944", 0.45 }, .{ "7801", 0.80 }, .{ "7802", 0.75 },
    .{ "7995", 0.85 }, .{ "4511", 0.35 }, .{ "5311", 0.25 },
    .{ "5999", 0.50 },
});
const MCC_DEFAULT: f64 = 0.5;

pub fn parseQuery(
    allocator: std.mem.Allocator,
    body: []const u8,
    vec_out: *[config.DIMS]f64
) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    try vectorize(parsed.value, vec_out);
}

fn vectorize(json: std.json.Value, vec_out: *[config.DIMS]f64) !void {
    @memset(vec_out, 0);

    const transaction = getObjectOpt(json, "transaction");
    const customer    = getObjectOpt(json, "customer");
    const merchant    = getObjectOpt(json, "merchant");
    const terminal    = getObjectOpt(json, "terminal");
    const last_tx_opt = getObjectOpt(json, "last_transaction");

    const tx_amount = getNumberOrDefault(transaction, "amount", 0);
    const cust_avg  = getNumberOrDefault(customer, "avg_amount", 0);

    const requested_at: ?DateTime = blk: {
        const s = getStringOpt(transaction, "requested_at") orelse break :blk null;
        break :blk parseIsoUtc(s) catch null;
    };

    // pos 0..2 (igual ao seu, sem o try)
    vec_out[0] = norm(tx_amount, MAX_AMOUNT);
    vec_out[1] = norm(getNumberOrDefault(transaction, "installments", 0), MAX_INSTALLMENTS);
    vec_out[2] = if (cust_avg > 0) norm(tx_amount / cust_avg, AMOUNT_VS_AVG_RATIO) else 0;

    // pos 3, 4
    if (requested_at) |req| {
        vec_out[3] = @as(f64, @floatFromInt(req.hour)) / 23.0;
        vec_out[4] = @as(f64, @floatFromInt(dayOfWeekMondayBased(req))) / 6.0;
    } else {
        vec_out[3] = 0.5;
        vec_out[4] = 0.5;
    }

    if (last_tx_opt) |last_tx| {
        vec_out[5] = blk: {
            const req = requested_at orelse break :blk -1.0;
            const ts_str = getStringOpt(last_tx, "timestamp") orelse break :blk -1.0;
            const ts = parseIsoUtc(ts_str) catch break :blk -1.0;
            const delta_s = epochSeconds(req) - epochSeconds(ts);
            const minutes = @as(f64, @floatFromInt(delta_s)) / 60.0;
            break :blk norm(minutes, MAX_MINUTES);
        };
        vec_out[6] = norm(getNumberOrDefault(last_tx, "km_from_current", 0), MAX_KM);
    } else {
        vec_out[5] = -1.0;
        vec_out[6] = -1.0;
    }

    vec_out[7]  = norm(getNumberOrDefault(terminal, "km_from_home", 0), MAX_KM);
    vec_out[8]  = norm(getNumberOrDefault(customer, "tx_count_24h", 0), MAX_TX_COUNT_24H);
    vec_out[9]  = boolToF64(getBoolOrDefault(terminal, "is_online", false));
    vec_out[10] = boolToF64(getBoolOrDefault(terminal, "card_present", false));

    vec_out[11] = blk: {
        const mid = getStringOpt(merchant, "id") orelse break :blk 1.0;
        const known = getArrayOpt(customer, "known_merchants") orelse break :blk 1.0;
        for (known.items) |item| {
            if (item == .string and std.mem.eql(u8, item.string, mid)) {
                break :blk 0.0;
            }
        }
        break :blk 1.0;
    };

    vec_out[12] = if (getStringOpt(merchant, "mcc")) |mcc|
        mcc_risk_table.get(mcc) orelse MCC_DEFAULT
    else
        MCC_DEFAULT;

    // pos 13
    vec_out[13] = norm(getNumberOrDefault(merchant, "avg_amount", 0), MAX_MERCHANT_AVG_AMOUNT);
}

fn getNumberOrDefault(obj_opt: ?std.json.Value, key: []const u8, default: f64) f64 {
    const obj = obj_opt orelse return default;
    const v = obj.object.get(key) orelse return default;
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => default,
    };
}

fn getBoolOrDefault(obj_opt: ?std.json.Value, key: []const u8, default: bool) bool {
    const obj = obj_opt orelse return default;
    const v = obj.object.get(key) orelse return default;
    return switch (v) {
        .bool => |b| b,
        else => default,
    };
}

fn getStringOpt(obj_opt: ?std.json.Value, key: []const u8) ?[]const u8 {
    const obj = obj_opt orelse return null;
    const v = obj.object.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn getObjectOpt(obj_opt: ?std.json.Value, key: []const u8) ?std.json.Value {
    const obj = obj_opt orelse return null;
    const v = obj.object.get(key) orelse return null;
    if (v != .object) return null;
    return v;
}

fn getArrayOpt(obj_opt: ?std.json.Value, key: []const u8) ?std.json.Array {
    const obj = obj_opt orelse return null;
    const v = obj.object.get(key) orelse return null;
    if (v != .array) return null;
    return v.array;
}

fn norm(value: f64, max: f64) f64 {
    const ratio = value / max;
    return @max(0.0, @min(1.0, ratio));
}

inline fn boolToF64(b: bool) f64 {
    return if (b) 1.0 else 0.0;
}

pub const DateTime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

inline fn parseDigits(s: []const u8) !u32 {
    var v: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return error.InvalidDigit;
        v = v * 10 + (c - '0');
    }
    return v;
}

pub fn parseIsoUtc(s: []const u8) !DateTime {
    if (s.len < 20) return error.InvalidDateTime;
    if (s[4]  != '-' or s[7]  != '-' or s[10] != 'T' or
        s[13] != ':' or s[16] != ':' or s[19] != 'Z')
    {
        return error.InvalidDateTime;
    }
    return .{
        .year   = @intCast(try parseDigits(s[0..4])),
        .month  = @intCast(try parseDigits(s[5..7])),
        .day    = @intCast(try parseDigits(s[8..10])),
        .hour   = @intCast(try parseDigits(s[11..13])),
        .minute = @intCast(try parseDigits(s[14..16])),
        .second = @intCast(try parseDigits(s[17..19])),
    };
}

fn sakamotoDow(year: u16, month: u8, day: u8) u8 {
    const t = [_]u8{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    var y: i32 = year;
    if (month < 3) y -= 1;
    const idx: i32 = y + @divTrunc(y, 4) - @divTrunc(y, 100) + @divTrunc(y, 400)
                   + @as(i32, t[month - 1]) + @as(i32, day);
    return @intCast(@mod(idx, 7));
}

pub fn dayOfWeekMondayBased(dt: DateTime) u8 {
    return (sakamotoDow(dt.year, dt.month, dt.day) + 6) % 7;
}

fn daysFromCivil(year: i32, month: u8, day: u8) i64 {
    const y: i32 = year - @as(i32, if (month <= 2) 1 else 0);
    const era: i32 = @divFloor(y, 400);
    const yoe: u32 = @intCast(y - era * 400);
    const m: u32 = month;
    const m_shifted: u32 = if (m > 2) m - 3 else m + 9;
    const doy: u32 = (153 * m_shifted + 2) / 5 + day - 1;
    const doe: u32 = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return @as(i64, era) * 146097 + @as(i64, doe) - 719468;
}

pub fn epochSeconds(dt: DateTime) i64 {
    return daysFromCivil(dt.year, dt.month, dt.day) * 86_400
         + @as(i64, dt.hour)   * 3_600
         + @as(i64, dt.minute) * 60
         + @as(i64, dt.second);
}
