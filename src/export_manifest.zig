const std = @import("std");

pub fn run() !void {
    const manifest =
        \\{
        \\  "schema_version": 1,
        \\  "name": "nulltickets",
        \\  "display_name": "NullTickets",
        \\  "description": "Headless task and issue tracker for AI agents",
        \\  "icon": "tickets",
        \\  "repo": "nullclaw/nulltickets",
        \\  "platforms": {
        \\    "aarch64-macos": { "asset": "nulltickets-macos-aarch64", "binary": "nulltickets" },
        \\    "x86_64-macos": { "asset": "nulltickets-macos-x86_64", "binary": "nulltickets" },
        \\    "x86_64-linux": { "asset": "nulltickets-linux-x86_64", "binary": "nulltickets" },
        \\    "aarch64-linux": { "asset": "nulltickets-linux-aarch64", "binary": "nulltickets" },
        \\    "riscv64-linux": { "asset": "nulltickets-linux-riscv64", "binary": "nulltickets" },
        \\    "x86_64-windows": { "asset": "nulltickets-windows-x86_64.exe", "binary": "nulltickets.exe" },
        \\    "aarch64-windows": { "asset": "nulltickets-windows-aarch64.exe", "binary": "nulltickets.exe" }
        \\  },
        \\  "build_from_source": {
        \\    "zig_version": "0.15.2",
        \\    "command": "zig build -Doptimize=ReleaseSmall",
        \\    "output": "zig-out/bin/nulltickets"
        \\  },
        \\  "launch": { "command": "nulltickets", "args": [] },
        \\  "health": { "endpoint": "/health", "port_from_config": "port" },
        \\  "ports": [{ "name": "api", "config_key": "port", "default": 7700, "protocol": "http" }],
        \\  "wizard": { "steps": [
        \\    { "id": "port", "title": "API Port", "type": "number", "required": true, "options": [] },
        \\    { "id": "db_path", "title": "Database Path", "type": "text", "required": true, "options": [] }
        \\  ] },
        \\  "depends_on": [],
        \\  "connects_to": []
        \\}
    ;
    const stdout = std.fs.File.stdout();
    try stdout.writeAll(manifest);
    try stdout.writeAll("\n");
}
