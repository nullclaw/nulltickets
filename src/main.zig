const std = @import("std");
const Store = @import("store.zig").Store;
const api = @import("api.zig");

const version = "0.1.0";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // skip program name

    var port: u16 = 7700;
    var db_path: [:0]const u8 = "nulltracker.db";

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            if (args.next()) |val| {
                port = std.fmt.parseInt(u16, val, 10) catch {
                    std.debug.print("invalid port: {s}\n", .{val});
                    return;
                };
            }
        } else if (std.mem.eql(u8, arg, "--db")) {
            if (args.next()) |val| {
                db_path = val;
            }
        } else if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("nulltracker v{s}\n", .{version});
            return;
        }
    }

    std.debug.print("nulltracker v{s}\n", .{version});
    std.debug.print("opening database: {s}\n", .{db_path});

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

const max_request_size: usize = 65_536;
