const std = @import("std");
const std_compat = @import("compat.zig");
const Store = @import("store.zig").Store;
const api = @import("api.zig");
const config = @import("config.zig");

const version = "2026.3.2";

pub fn main(init: std.process.Init) !void {
    std_compat.initProcess(init);
    const allocator = std.heap.smp_allocator;

    const args = try std_compat.process.argsAlloc(allocator);
    defer std_compat.process.argsFree(allocator, args);

    // Check for manifest protocol flags before normal arg parsing
    if (args.len > 1) {
        const first_arg = args[1];
        if (std.mem.eql(u8, first_arg, "--export-manifest")) {
            try @import("export_manifest.zig").run();
            return;
        }
        if (std.mem.eql(u8, first_arg, "--from-json")) {
            if (args.len > 2) {
                const json_str = args[2];
                try @import("from_json.zig").run(allocator, json_str);
            } else {
                std.debug.print("error: --from-json requires a JSON argument\n", .{});
                std.process.exit(1);
            }
            return;
        }
    }

    var port_override: ?u16 = null;
    var db_override: ?[:0]const u8 = null;
    var token_override: ?[]const u8 = null;
    var config_path_override: ?[]const u8 = null;

    var arg_index: usize = 1;
    while (arg_index < args.len) : (arg_index += 1) {
        const arg = args[arg_index];
        if (std.mem.eql(u8, arg, "--port")) {
            if (arg_index + 1 < args.len) {
                arg_index += 1;
                const val = args[arg_index];
                port_override = std.fmt.parseInt(u16, val, 10) catch {
                    std.debug.print("invalid port: {s}\n", .{val});
                    return;
                };
            }
        } else if (std.mem.eql(u8, arg, "--db")) {
            if (arg_index + 1 < args.len) {
                arg_index += 1;
                const val = args[arg_index];
                db_override = val;
            }
        } else if (std.mem.eql(u8, arg, "--token")) {
            if (arg_index + 1 < args.len) {
                arg_index += 1;
                const val = args[arg_index];
                token_override = val;
            }
        } else if (std.mem.eql(u8, arg, "--config")) {
            if (arg_index + 1 < args.len) {
                arg_index += 1;
                const val = args[arg_index];
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

    const addr = std.Io.net.IpAddress.resolve(std_compat.io(), "127.0.0.1", port) catch |err| {
        std.debug.print("failed to resolve address: {}\n", .{err});
        return;
    };
    var server = addr.listen(std_compat.io(), .{ .reuse_address = true }) catch |err| {
        std.debug.print("failed to listen on port {d}: {}\n", .{ port, err });
        return;
    };
    defer server.deinit(std_compat.io());

    std.debug.print("listening on http://127.0.0.1:{d}\n", .{port});

    while (true) {
        var conn = server.accept(std_compat.io()) catch |err| {
            std.debug.print("accept error: {}\n", .{err});
            continue;
        };
        defer conn.close(std_compat.io());

        // Per-request arena
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const req_alloc = arena.allocator();

        // Read request
        const full_request = readHttpRequest(req_alloc, &conn, max_request_size) catch continue orelse continue;

        // Parse request line
        const first_line_end = std.mem.indexOf(u8, full_request, "\r\n") orelse continue;
        const first_line = full_request[0..first_line_end];
        var parts = std.mem.splitScalar(u8, first_line, ' ');
        const method = parts.next() orelse continue;
        const target = parts.next() orelse continue;

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
        var resp_write_buffer: [1024]u8 = undefined;
        var writer = conn.writer(std_compat.io(), &resp_write_buffer);
        writer.interface.writeAll(header) catch continue;
        writer.interface.writeAll(response.body) catch continue;
        writer.interface.flush() catch continue;
    }
}

fn ensureParentDirForFile(path: []const u8) !void {
    if (path.len == 0 or std.mem.eql(u8, path, ":memory:") or std.mem.startsWith(u8, path, "file:")) return;

    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0) return;

    if (std.fs.path.isAbsolute(parent)) {
        std_compat.fs.makeDirAbsolute(parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        return;
    }

    try std_compat.fs.cwd().makePath(parent);
}

const max_request_size: usize = 65_536;
const request_read_chunk: usize = 4096;

fn readHttpRequest(allocator: std.mem.Allocator, stream: *std.Io.net.Stream, max_bytes: usize) !?[]u8 {
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(allocator);

    var read_buffer: [request_read_chunk]u8 = undefined;
    var reader = stream.reader(std_compat.io(), &read_buffer);

    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                if (buffer.items.len == 0) return null;
                return error.UnexpectedEof;
            },
            else => |e| return e,
        };

        try buffer.appendSlice(allocator, line);
        if (buffer.items.len > max_bytes) return error.RequestTooLarge;

        if (std.mem.eql(u8, line, "\r\n") or std.mem.eql(u8, line, "\n")) break;
    }

    const header_end = std.mem.indexOf(u8, buffer.items, "\r\n\r\n") orelse return error.InvalidRequest;
    const content_len = if (api.extractHeader(buffer.items[0 .. header_end + 4], "Content-Length")) |cl_str|
        (std.fmt.parseInt(usize, cl_str, 10) catch return error.InvalidContentLength)
    else
        0;

    const required = header_end + 4 + content_len;
    if (required > max_bytes) return error.RequestTooLarge;

    if (content_len > 0) {
        const body = try allocator.alloc(u8, content_len);
        defer allocator.free(body);
        try reader.interface.readSliceAll(body);
        try buffer.appendSlice(allocator, body);
    }

    return try allocator.dupe(u8, buffer.items[0..required]);
}

// Pull module test declarations into the test build (zig build test).
test {
    _ = @import("store.zig");
    _ = @import("api.zig");
    _ = @import("domain.zig");
    _ = @import("config.zig");
}
