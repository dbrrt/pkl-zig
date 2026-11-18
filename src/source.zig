const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const ModuleSource = struct {
    uri: []const u8,
    text: ?[]const u8 = null,
};

pub fn textSource(text: []const u8) ModuleSource {
    return .{ .uri = "repl:text", .text = text };
}

pub fn textSourceUri(text: []const u8, uri: []const u8) ModuleSource {
    return .{ .uri = uri, .text = text };
}

pub fn uriSource(uri: []const u8) ModuleSource {
    return .{ .uri = uri };
}

/// Absolute `file://` URI for `path`. The path must exist.
pub fn fileUri(gpa: Allocator, io: Io, path: []const u8) ![]u8 {
    const absolute = try Io.Dir.cwd().realPathFileAlloc(io, path, gpa);
    defer gpa.free(absolute);
    return fileUriFromAbsolute(gpa, absolute);
}

pub fn fileUriFromAbsolute(gpa: Allocator, absolute: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "file://");
    if (std.fs.path.sep == '\\') try out.append(gpa, '/');
    for (absolute) |byte| {
        const c: u8 = if (byte == '\\') '/' else byte;
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~', '/', ':' => try out.append(gpa, c),
            else => {
                const hex = "0123456789ABCDEF";
                try out.appendSlice(gpa, &.{ '%', hex[c >> 4], hex[c & 0xf] });
            },
        }
    }
    return out.toOwnedSlice(gpa);
}
