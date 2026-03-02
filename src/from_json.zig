const std = @import("std");

pub fn run(allocator: std.mem.Allocator, json_str: []const u8) !void {
    const parsed = std.json.parseFromSlice(
        struct { port: u16 = 7700, db_path: []const u8 = "nulltickets.db" },
        allocator,
        json_str,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch {
        std.debug.print("error: invalid JSON\n", .{});
        std.process.exit(1);
    };
    defer parsed.deinit();

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try std.fmt.format(w, "{{\n  \"port\": {d},\n  \"db\": \"{s}\"\n}}\n", .{ parsed.value.port, parsed.value.db_path });

    const file = try std.fs.cwd().createFile("config.json", .{});
    defer file.close();
    try file.writeAll(buf.items);

    const stdout = std.fs.File.stdout();
    try stdout.writeAll("{\"status\":\"ok\"}\n");
}
