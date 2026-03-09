const std = @import("std");
const builtin = @import("builtin");

pub const home_env_var = "NULLTICKETS_HOME";
pub const home_dir_name = ".nulltickets";

pub const Config = struct {
    port: u16 = 7700,
    db: []const u8 = "nulltickets.db",
    api_token: ?[]const u8 = null,
};

pub fn resolveConfigPath(allocator: std.mem.Allocator, override_path: ?[]const u8) ![]const u8 {
    if (override_path) |path| return allocator.dupe(u8, path);

    const home_dir = try resolveHomeDir(allocator);
    defer allocator.free(home_dir);
    return std.fs.path.join(allocator, &.{ home_dir, "config.json" });
}

pub fn resolveHomeDir(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, home_env_var)) |env_home| {
        return env_home;
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }

    const home = try getHomeDirOwned(allocator);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, home_dir_name });
}

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

pub fn resolveRelativePaths(allocator: std.mem.Allocator, config_path: []const u8, cfg: *Config) !void {
    cfg.db = try resolveRelativePath(allocator, config_path, cfg.db);
}

fn resolveRelativePath(allocator: std.mem.Allocator, config_path: []const u8, value: []const u8) ![]const u8 {
    if (value.len == 0 or std.fs.path.isAbsolute(value)) return value;

    const base_dir = std.fs.path.dirname(config_path) orelse ".";
    return std.fs.path.resolve(allocator, &.{ base_dir, value });
}

fn getHomeDirOwned(allocator: std.mem.Allocator) ![]u8 {
    return std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            if (builtin.os.tag == .windows) {
                return std.process.getEnvVarOwned(allocator, "USERPROFILE") catch error.HomeNotSet;
            }
            return error.HomeNotSet;
        },
        else => return err,
    };
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

test "resolveRelativePaths anchors db to config directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("configs");
    try tmp.dir.writeFile(.{
        .sub_path = "configs/config.json",
        .data =
        \\{
        \\  "db": "data/nulltickets.db"
        \\}
        ,
    });

    const cfg_path = try tmp.dir.realpathAlloc(std.testing.allocator, "configs/config.json");
    defer std.testing.allocator.free(cfg_path);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var cfg = try loadFromFile(arena.allocator(), cfg_path);
    try resolveRelativePaths(arena.allocator(), cfg_path, &cfg);

    const config_dir = std.fs.path.dirname(cfg_path).?;
    const expected_db = try std.fs.path.resolve(arena.allocator(), &.{ config_dir, "data/nulltickets.db" });
    try std.testing.expectEqualStrings(expected_db, cfg.db);
}
