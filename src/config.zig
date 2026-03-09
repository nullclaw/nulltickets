const std = @import("std");

pub const Config = struct {
    port: u16 = 7700,
    db: []const u8 = "nulltickets.db",
    api_token: ?[]const u8 = null,
};

/// Load runtime config from JSON file. Missing file means defaults.
/// The caller should provide an arena allocator since returned slices may point
/// to parser-owned allocations.
pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Config {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) return Config{};
        return err;
    };
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 1024 * 1024);
    const parsed = try std.json.parseFromSlice(Config, allocator, contents, .{ .ignore_unknown_fields = true });
    return parsed.value;
}

test "loadFromFile returns defaults when missing" {
    const cfg = try loadFromFile(std.testing.allocator, "nonexistent-config-file-12345.json");
    try std.testing.expectEqual(@as(u16, 7700), cfg.port);
    try std.testing.expectEqualStrings("nulltickets.db", cfg.db);
    try std.testing.expectEqual(@as(?[]const u8, null), cfg.api_token);
}

test "loadFromFile reads config values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "config.json",
        .data =
        \\{
        \\  "port": 7788,
        \\  "db": "tickets.db",
        \\  "api_token": "secret"
        \\}
        ,
    });

    const cfg_path = try tmp.dir.realpathAlloc(std.testing.allocator, "config.json");
    defer std.testing.allocator.free(cfg_path);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cfg = try loadFromFile(arena.allocator(), cfg_path);
    try std.testing.expectEqual(@as(u16, 7788), cfg.port);
    try std.testing.expectEqualStrings("tickets.db", cfg.db);
    try std.testing.expectEqualStrings("secret", cfg.api_token.?);
}
