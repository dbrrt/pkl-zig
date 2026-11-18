//! A MessagePack codec covering the subset Pkl's message-passing API and
//! `pkl-binary` encoding use: nil, bool, int, float, string, binary, array, map.
//! Extension types are rejected.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;

pub const Error = Reader.Error || error{
    InvalidMessagePack,
    IntegerOverflow,
    UnsupportedMessagePack,
    OutOfMemory,
};

pub const Header = union(enum) {
    nil,
    boolean: bool,
    int: i64,
    float: f64,
    string: u32,
    binary: u32,
    array: u32,
    map: u32,
};

pub const Value = union(enum) {
    nil,
    boolean: bool,
    int: i64,
    float: f64,
    string: []u8,
    binary: []u8,
    array: []Value,
    map: []Entry,

    pub const Entry = struct {
        key: Value,
        value: Value,
    };

    pub fn deinit(self: *Value, gpa: Allocator) void {
        switch (self.*) {
            .nil, .boolean, .int, .float => {},
            .string => |s| gpa.free(s),
            .binary => |b| gpa.free(b),
            .array => |items| {
                for (items) |*item| item.deinit(gpa);
                gpa.free(items);
            },
            .map => |entries| {
                for (entries) |*entry| {
                    entry.key.deinit(gpa);
                    entry.value.deinit(gpa);
                }
                gpa.free(entries);
            },
        }
    }

    pub fn get(self: Value, key: []const u8) ?Value {
        const entries = switch (self) {
            .map => |entries| entries,
            else => return null,
        };
        for (entries) |entry| {
            switch (entry.key) {
                .string => |s| if (std.mem.eql(u8, s, key)) return entry.value,
                else => {},
            }
        }
        return null;
    }
};

pub fn readHeader(r: *Reader) Error!Header {
    const tag = try r.takeByte();
    switch (tag) {
        0x00...0x7f => return .{ .int = tag },
        0xe0...0xff => return .{ .int = @as(i8, @bitCast(tag)) },
        0xc0 => return .nil,
        0xc2 => return .{ .boolean = false },
        0xc3 => return .{ .boolean = true },
        0xc4 => return .{ .binary = try r.takeByte() },
        0xc5 => return .{ .binary = try r.takeInt(u16, .big) },
        0xc6 => return .{ .binary = try r.takeInt(u32, .big) },
        0xca => {
            const bits = try r.takeInt(u32, .big);
            return .{ .float = @floatCast(@as(f32, @bitCast(bits))) };
        },
        0xcb => {
            const bits = try r.takeInt(u64, .big);
            return .{ .float = @bitCast(bits) };
        },
        0xcc => return .{ .int = try r.takeByte() },
        0xcd => return .{ .int = try r.takeInt(u16, .big) },
        0xce => return .{ .int = try r.takeInt(u32, .big) },
        0xcf => {
            const wide = try r.takeInt(u64, .big);
            if (wide > std.math.maxInt(i64)) return error.IntegerOverflow;
            return .{ .int = @intCast(wide) };
        },
        0xd0 => return .{ .int = try r.takeByteSigned() },
        0xd1 => return .{ .int = try r.takeInt(i16, .big) },
        0xd2 => return .{ .int = try r.takeInt(i32, .big) },
        0xd3 => return .{ .int = try r.takeInt(i64, .big) },
        0xd9 => return .{ .string = try r.takeByte() },
        0xda => return .{ .string = try r.takeInt(u16, .big) },
        0xdb => return .{ .string = try r.takeInt(u32, .big) },
        0xdc => return .{ .array = try r.takeInt(u16, .big) },
        0xdd => return .{ .array = try r.takeInt(u32, .big) },
        0xde => return .{ .map = try r.takeInt(u16, .big) },
        0xdf => return .{ .map = try r.takeInt(u32, .big) },
        0xa0...0xbf => return .{ .string = tag & 0x1f },
        0x90...0x9f => return .{ .array = tag & 0x0f },
        0x80...0x8f => return .{ .map = tag & 0x0f },
        0xc1, 0xc7, 0xc8, 0xc9, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8 => return error.UnsupportedMessagePack,
    }
}

pub fn readCounted(r: *Reader, gpa: Allocator, len: usize) Error![]u8 {
    const buf = try gpa.alloc(u8, len);
    errdefer gpa.free(buf);
    if (len == 0) return buf;
    const got = try r.take(len);
    @memcpy(buf, got);
    return buf;
}

pub fn skip(r: *Reader) Error!void {
    switch (try readHeader(r)) {
        .nil, .boolean, .int, .float => {},
        .string, .binary => |len| try skipBytes(r, len),
        .array => |len| {
            for (0..len) |_| try skip(r);
        },
        .map => |len| {
            for (0..len) |_| {
                try skip(r);
                try skip(r);
            }
        },
    }
}

fn skipBytes(r: *Reader, len: usize) Error!void {
    var left = len;
    while (left > 0) {
        const n = try r.discard(.limited(left));
        if (n == 0) return error.EndOfStream;
        left -= n;
    }
}

pub fn decode(r: *Reader, gpa: Allocator) Error!Value {
    switch (try readHeader(r)) {
        .nil => return .nil,
        .boolean => |b| return .{ .boolean = b },
        .int => |i| return .{ .int = i },
        .float => |f| return .{ .float = f },
        .string => |len| return .{ .string = try readCounted(r, gpa, len) },
        .binary => |len| return .{ .binary = try readCounted(r, gpa, len) },
        .array => |len| {
            const items = try gpa.alloc(Value, len);
            var filled: usize = 0;
            errdefer {
                for (items[0..filled]) |*item| item.deinit(gpa);
                gpa.free(items);
            }
            for (items) |*item| {
                item.* = try decode(r, gpa);
                filled += 1;
            }
            return .{ .array = items };
        },
        .map => |len| {
            const entries = try gpa.alloc(Value.Entry, len);
            var filled: usize = 0;
            errdefer {
                for (entries[0..filled]) |*entry| {
                    entry.key.deinit(gpa);
                    entry.value.deinit(gpa);
                }
                gpa.free(entries);
            }
            for (entries) |*entry| {
                entry.key = try decode(r, gpa);
                entry.value = try decode(r, gpa);
                filled += 1;
            }
            return .{ .map = entries };
        },
    }
}

pub const Encoder = struct {
    bytes: std.ArrayList(u8) = .empty,
    gpa: Allocator,

    pub fn init(gpa: Allocator) Encoder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Encoder) void {
        self.bytes.deinit(self.gpa);
    }

    pub fn toOwnedSlice(self: *Encoder) Allocator.Error![]u8 {
        return self.bytes.toOwnedSlice(self.gpa);
    }

    pub fn nil(self: *Encoder) Allocator.Error!void {
        try self.bytes.append(self.gpa, 0xc0);
    }

    pub fn boolean(self: *Encoder, value: bool) Allocator.Error!void {
        try self.bytes.append(self.gpa, if (value) 0xc3 else 0xc2);
    }

    pub fn int(self: *Encoder, value: i64) Allocator.Error!void {
        if (value >= 0) {
            const u: u64 = @intCast(value);
            if (u <= 0x7f) {
                try self.bytes.append(self.gpa, @intCast(u));
            } else if (u <= 0xff) {
                try self.bytes.append(self.gpa, 0xcc);
                try self.bytes.append(self.gpa, @intCast(u));
            } else if (u <= 0xffff) {
                try self.bytes.append(self.gpa, 0xcd);
                try self.writeU16(@intCast(u));
            } else if (u <= 0xffffffff) {
                try self.bytes.append(self.gpa, 0xce);
                try self.writeU32(@intCast(u));
            } else {
                try self.bytes.append(self.gpa, 0xcf);
                try self.writeU64(u);
            }
            return;
        }
        if (value >= -32) {
            try self.bytes.append(self.gpa, @bitCast(@as(i8, @intCast(value))));
        } else if (value >= std.math.minInt(i8)) {
            try self.bytes.append(self.gpa, 0xd0);
            try self.bytes.append(self.gpa, @bitCast(@as(i8, @intCast(value))));
        } else if (value >= std.math.minInt(i16)) {
            try self.bytes.append(self.gpa, 0xd1);
            try self.writeU16(@bitCast(@as(i16, @intCast(value))));
        } else if (value >= std.math.minInt(i32)) {
            try self.bytes.append(self.gpa, 0xd2);
            try self.writeU32(@bitCast(@as(i32, @intCast(value))));
        } else {
            try self.bytes.append(self.gpa, 0xd3);
            try self.writeU64(@bitCast(value));
        }
    }

    pub fn float(self: *Encoder, value: f64) Allocator.Error!void {
        try self.bytes.append(self.gpa, 0xcb);
        try self.writeU64(@bitCast(value));
    }

    pub fn string(self: *Encoder, value: []const u8) Allocator.Error!void {
        if (value.len <= 31) {
            try self.bytes.append(self.gpa, 0xa0 | @as(u8, @intCast(value.len)));
        } else if (value.len <= 0xff) {
            try self.bytes.append(self.gpa, 0xd9);
            try self.bytes.append(self.gpa, @intCast(value.len));
        } else if (value.len <= 0xffff) {
            try self.bytes.append(self.gpa, 0xda);
            try self.writeU16(@intCast(value.len));
        } else {
            try self.bytes.append(self.gpa, 0xdb);
            try self.writeU32(@intCast(value.len));
        }
        try self.bytes.appendSlice(self.gpa, value);
    }

    pub fn binary(self: *Encoder, value: []const u8) Allocator.Error!void {
        if (value.len <= 0xff) {
            try self.bytes.append(self.gpa, 0xc4);
            try self.bytes.append(self.gpa, @intCast(value.len));
        } else if (value.len <= 0xffff) {
            try self.bytes.append(self.gpa, 0xc5);
            try self.writeU16(@intCast(value.len));
        } else {
            try self.bytes.append(self.gpa, 0xc6);
            try self.writeU32(@intCast(value.len));
        }
        try self.bytes.appendSlice(self.gpa, value);
    }

    pub fn array(self: *Encoder, len: usize) Allocator.Error!void {
        try self.prefix(0x90, 0xdc, 0xdc, 0xdd, len);
    }

    pub fn map(self: *Encoder, len: usize) Allocator.Error!void {
        try self.prefix(0x80, 0xde, 0xde, 0xdf, len);
    }

    fn prefix(self: *Encoder, fix: u8, wide16: u8, _: u8, wide32: u8, len: usize) Allocator.Error!void {
        const fix_max: usize = if (fix == 0xa0) 31 else 15;
        if (len <= fix_max) {
            try self.bytes.append(self.gpa, fix | @as(u8, @intCast(len)));
        } else if (len <= 0xffff) {
            try self.bytes.append(self.gpa, wide16);
            try self.writeU16(@intCast(len));
        } else {
            try self.bytes.append(self.gpa, wide32);
            try self.writeU32(@intCast(len));
        }
    }

    fn writeU16(self: *Encoder, value: u16) Allocator.Error!void {
        const bytes = std.mem.toBytes(std.mem.nativeToBig(u16, value));
        try self.bytes.appendSlice(self.gpa, &bytes);
    }

    fn writeU32(self: *Encoder, value: u32) Allocator.Error!void {
        const bytes = std.mem.toBytes(std.mem.nativeToBig(u32, value));
        try self.bytes.appendSlice(self.gpa, &bytes);
    }

    fn writeU64(self: *Encoder, value: u64) Allocator.Error!void {
        const bytes = std.mem.toBytes(std.mem.nativeToBig(u64, value));
        try self.bytes.appendSlice(self.gpa, &bytes);
    }
};

test "roundtrip primitives and collections" {
    const gpa = std.testing.allocator;
    var enc = Encoder.init(gpa);
    defer enc.deinit();
    try enc.array(4);
    try enc.int(-32);
    try enc.string("pkl");
    try enc.map(1);
    try enc.string("k");
    try enc.boolean(true);
    try enc.binary(&.{ 1, 2, 3 });

    var reader = Reader.fixed(enc.bytes.items);
    var value = try decode(&reader, gpa);
    defer value.deinit(gpa);

    const items = value.array;
    try std.testing.expectEqual(@as(i64, -32), items[0].int);
    try std.testing.expectEqualStrings("pkl", items[1].string);
    try std.testing.expect(items[2].get("k").?.boolean);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, items[3].binary);
}
