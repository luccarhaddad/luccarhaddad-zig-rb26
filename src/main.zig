const std = @import("std");
const config = @import("config.zig");
const dataset_mod = @import("dataset.zig");
const server_mod = @import("server.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const persistent = std.heap.page_allocator;

    // ---- Modo gerador: ./binário --gen-bin ----
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len >= 2 and std.mem.eql(u8, args[1], "--gen-bin")) {
        std.debug.print("Gerando references.bin a partir de .gz (com IVF)...\n", .{});
        try dataset_mod.genBin(io, persistent, config.REFERENCES_PATH, "references.bin");
        return;
    }

    // ---- Modo servidor ----
    std.debug.print("Carregando dataset do .bin...\n", .{});
    var dataset = try dataset_mod.loadFromBin(persistent, io, "references.bin");
    defer dataset.deinit();

    std.debug.print("Pronto. Memória estável: ~{d} MB\n", .{
        (config.VECTORS_BYTES + config.LABELS_BYTES) / (1024 * 1024),
    });

    try server_mod.serve(io, persistent, &dataset);
}
