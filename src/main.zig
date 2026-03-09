const std = @import("std");
const Store = @import("store.zig").Store;
const api = @import("api.zig");
const config = @import("config.zig");

const version = "2026.3.2";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // skip program name

    // Check for manifest protocol flags before normal arg parsing
    if (args.next()) |first_arg| {
        if (std.mem.eql(u8, first_arg, "--export-manifest")) {
            try @import("export_manifest.zig").run();
            return;
        }
        if (std.mem.eql(u8, first_arg, "--from-json")) {
            if (args.next()) |json_str| {
                try @import("from_json.zig").run(allocator, json_str);
            } else {
                std.debug.print("error: --from-json requires a JSON argument\n", .{});
                std.process.exit(1);
            }
            return;
        }
    }

    // Re-parse all args for normal operation
    var args2 = try std.process.argsWithAllocator(allocator);
    defer args2.deinit();
    _ = args2.next(); // skip program name

    var port_override: ?u16 = null;
    var db_override: ?[:0]const u8 = null;
    var token_override: ?[]const u8 = null;
    var config_path_override: ?[]const u8 = null;

    while (args2.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            if (args2.next()) |val| {
                port_override = std.fmt.parseInt(u16, val, 10) catch {
                    std.debug.print("invalid port: {s}\n", .{val});
                    return;
                };
            }
        } else if (std.mem.eql(u8, arg, "--db")) {
            if (args2.next()) |val| {
                db_override = val;
            }
        } else if (std.mem.eql(u8, arg, "--token")) {
            if (args2.next()) |val| {
                token_override = val;
            }
        } else if (std.mem.eql(u8, arg, "--config")) {
            if (args2.next()) |val| {
                config_path_override = val;
            }
        } else if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("nulltickets v{s}\n", .{version});
            return;
        }
    }

    var cfg_arena = std.heap.ArenaAllocator.init(allocator);
    defer cfg_arena.deinit();
    const config_path = config.resolveConfigPath(cfg_arena.allocator(), config_path_override) catch |err| {
        std.debug.print("failed to resolve config path: {}\n", .{err});
        return;
    };
    var cfg = config.loadFromFile(cfg_arena.allocator(), config_path) catch |err| {
        std.debug.print("failed to load config from {s}: {}\n", .{ config_path, err });
        return;
    };
    config.resolveRelativePaths(cfg_arena.allocator(), config_path, &cfg) catch |err| {
        std.debug.print("failed to resolve config paths from {s}: {}\n", .{ config_path, err });
        return;
    };

    const port = port_override orelse cfg.port;
    const api_token = token_override orelse cfg.api_token;
    const db_path: [:0]const u8 = db_override orelse blk: {
        const db_z = cfg_arena.allocator().allocSentinel(u8, cfg.db.len, 0) catch {
            std.debug.print("out of memory\n", .{});
            return;
        };
        @memcpy(db_z, cfg.db);
        break :blk db_z;
    };

    std.debug.print("nulltickets v{s}\n", .{version});
    std.debug.print("opening database: {s}\n", .{db_path});
    if (api_token != null) {
        std.debug.print("API auth: bearer token enabled\n", .{});
    } else {
        std.debug.print("API auth: disabled\n", .{});
    }

    ensureParentDirForFile(db_path) catch |err| {
        std.debug.print("failed to create database directory for {s}: {}\n", .{ db_path, err });
        return;
    };

    var store = try Store.init(allocator, db_path);
    defer store.deinit();

    const addr = std.net.Address.resolveIp("127.0.0.1", port) catch |err| {
        std.debug.print("failed to resolve address: {}\n", .{err});
        return;
    };
    var server = addr.listen(.{ .reuse_address = true }) catch |err| {
        std.debug.print("failed to listen on port {d}: {}\n", .{ port, err });
        return;
    };
    defer server.deinit();

    std.debug.print("listening on http://127.0.0.1:{d}\n", .{port});

    while (true) {
        const conn = server.accept() catch |err| {
            std.debug.print("accept error: {}\n", .{err});
            continue;
        };
        defer conn.stream.close();

        // Per-request arena
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const req_alloc = arena.allocator();

        // Read request
        var req_buf: [max_request_size]u8 = undefined;
        const n = conn.stream.read(&req_buf) catch continue;
        if (n == 0) continue;
        const raw = req_buf[0..n];

        // Parse request line
        const first_line_end = std.mem.indexOf(u8, raw, "\r\n") orelse continue;
        const first_line = raw[0..first_line_end];
        var parts = std.mem.splitScalar(u8, first_line, ' ');
        const method = parts.next() orelse continue;
        const target = parts.next() orelse continue;

        // Read remaining body if Content-Length indicates more data
        var full_request = raw;
        if (api.extractHeader(raw, "Content-Length")) |cl_str| {
            const content_length = std.fmt.parseInt(usize, cl_str, 10) catch 0;
            if (content_length > 0) {
                const header_end_pos = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse continue;
                const body_start = header_end_pos + 4;
                const body_received = n - body_start;
                if (body_received < content_length) {
                    // Need to read more
                    const total_size = body_start + content_length;
                    if (total_size > max_request_size) continue;
                    const full_buf = req_alloc.alloc(u8, total_size) catch continue;
                    @memcpy(full_buf[0..n], raw);
                    var total_read = n;
                    while (total_read < total_size) {
                        const extra = conn.stream.read(full_buf[total_read..total_size]) catch break;
                        if (extra == 0) break;
                        total_read += extra;
                    }
                    full_request = full_buf[0..total_read];
                }
            }
        }

        const body = api.extractBody(full_request);

        var ctx = api.Context{
            .store = &store,
            .allocator = req_alloc,
            .required_api_token = api_token,
        };
        const response = api.handleRequest(&ctx, method, target, body, full_request);

        // Write response
        var resp_buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(
            &resp_buf,
            "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{ response.status, response.body.len },
        ) catch continue;
        _ = conn.stream.write(header) catch continue;
        _ = conn.stream.write(response.body) catch continue;
    }
}

fn ensureParentDirForFile(path: []const u8) !void {
    if (path.len == 0 or std.mem.eql(u8, path, ":memory:") or std.mem.startsWith(u8, path, "file:")) return;

    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0) return;

    if (std.fs.path.isAbsolute(parent)) {
        std.fs.makeDirAbsolute(parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        return;
    }

    std.fs.cwd().makePath(parent) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

const max_request_size: usize = 65_536;
