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

    const config_json = try std.json.Stringify.valueAlloc(allocator, .{
        .port = parsed.value.port,
        .db = parsed.value.db_path,
    }, .{ .whitespace = .indent_2 });
    defer allocator.free(config_json);

    const file = try std.fs.cwd().createFile("config.json", .{});
    defer file.close();
    try file.writeAll(config_json);
    try file.writeAll("\n");

    const stdout = std.fs.File.stdout();
    try stdout.writeAll("{\"status\":\"ok\"}\n");
}
