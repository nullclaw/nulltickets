const std = @import("std");

/// Generate a UUID v4 string (36 chars: 8-4-4-4-12)
pub fn generateId() [36]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);

    // Set version 4
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    // Set variant 1
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    var buf: [36]u8 = undefined;
    const hex = "0123456789abcdef";
    var out: usize = 0;
    for (bytes, 0..) |b, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            buf[out] = '-';
            out += 1;
        }
        buf[out] = hex[b >> 4];
        buf[out + 1] = hex[b & 0x0f];
        out += 2;
    }
    return buf;
}

/// Generate a 32-byte random token, return as 64-char hex string
pub fn generateToken() [64]u8 {
    var bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    return hexEncode(bytes);
}

/// SHA-256 hash, returns 32 bytes
pub fn hashToken(token_hex: []const u8) ![32]u8 {
    var token_bytes: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&token_bytes, token_hex) catch return error.InvalidToken;
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&token_bytes, &hash, .{});
    return hash;
}

/// SHA-256 hash of raw bytes
pub fn hashBytes(bytes: []const u8) [32]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return hash;
}

fn hexEncode(bytes: [32]u8) [64]u8 {
    var buf: [64]u8 = undefined;
    const hex = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        buf[i * 2] = hex[b >> 4];
        buf[i * 2 + 1] = hex[b & 0x0f];
    }
    return buf;
}

/// Current time in milliseconds since epoch
pub fn nowMs() i64 {
    return std.time.milliTimestamp();
}
