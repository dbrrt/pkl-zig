//! Decoder for Pkl's `pkl-binary` value encoding.
//! https://pkl-lang.org/main/current/bindings-specification/binary-encoding.html
//!
//! Non-primitive values are MessagePack arrays whose first slot is a type code.
//! Slots past the ones this decoder knows are skipped so newer Pkl releases
//! remain readable.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const msgpack = @import("msgpack.zig");
const value = @import("value.zig");

pub const Error = msgpack.Error || error{
    InvalidPkl,
    UnknownType,
    UnknownUnit,
    FunctionValue,
};

const Code = struct {
    const object: i64 = 0x01;
    const map: i64 = 0x02;
    const mapping: i64 = 0x03;
    const list: i64 = 0x04;
    const listing: i64 = 0x05;
    const set: i64 = 0x06;
    const duration: i64 = 0x07;
    const data_size: i64 = 0x08;
    const pair: i64 = 0x09;
    const int_seq: i64 = 0x0a;
    const regex: i64 = 0x0b;
    const class: i64 = 0x0c;
    const type_alias: i64 = 0x0d;
    const function: i64 = 0x0e;
    const bytes: i64 = 0x0f;
    const property: i64 = 0x10;
    const entry: i64 = 0x11;
    const element: i64 = 0x12;
};

pub fn decode(allocator: Allocator, bytes: []const u8) Error!value.Value {
    var reader = Reader.fixed(bytes);
    return decodeReader(allocator, &reader);
}

pub fn decodeReader(allocator: Allocator, r: *Reader) Error!value.Value {
    return decodeValue(allocator, r);
}

fn decodeValue(allocator: Allocator, r: *Reader) Error!value.Value {
    switch (try msgpack.readHeader(r)) {
        .nil => return .null,
        .boolean => |b| return .{ .boolean = b },
        .int => |n| return .{ .int = n },
        .float => |n| return .{ .float = n },
        .string => |len| return .{ .string = try msgpack.readCounted(r, allocator, len) },
        .binary => |len| return .{ .bytes = try msgpack.readCounted(r, allocator, len) },
        .array => |len| return decodeTagged(allocator, r, len),
        .map => return error.InvalidPkl,
    }
}

fn decodeTagged(allocator: Allocator, r: *Reader, len: u32) Error!value.Value {
    if (len == 0) return error.InvalidPkl;
    const code = try expectInt(r);
    switch (code) {
        Code.object => return decodeObject(allocator, r, len),
        Code.map, Code.mapping => {
            const decoded = try decodeMap(allocator, r);
            try skipRest(r, len, 2);
            return decoded;
        },
        Code.list, Code.listing => {
            const items = try decodeList(allocator, r);
            errdefer freeList(allocator, items);
            try skipRest(r, len, 2);
            return .{ .list = items };
        },
        Code.set => {
            const items = try decodeList(allocator, r);
            errdefer freeList(allocator, items);
            try skipRest(r, len, 2);
            return .{ .set = items };
        },
        Code.duration => {
            const magnitude = try expectNumber(r);
            const unit_text = try expectString(allocator, r);
            errdefer allocator.free(unit_text);
            try skipRest(r, len, 3);
            const unit = value.parseDurationUnit(unit_text) catch return error.UnknownUnit;
            allocator.free(unit_text);
            return .{ .duration = .{ .value = magnitude, .unit = unit } };
        },
        Code.data_size => {
            const magnitude = try expectNumber(r);
            const unit_text = try expectString(allocator, r);
            errdefer allocator.free(unit_text);
            try skipRest(r, len, 3);
            const unit = value.parseDataSizeUnit(unit_text) catch return error.UnknownUnit;
            allocator.free(unit_text);
            return .{ .data_size = .{ .value = magnitude, .unit = unit } };
        },
        Code.pair => {
            const pair = try allocator.create(value.Pair);
            errdefer allocator.destroy(pair);
            pair.first = try decodeValue(allocator, r);
            errdefer pair.first.deinit(allocator);
            pair.second = try decodeValue(allocator, r);
            errdefer pair.second.deinit(allocator);
            try skipRest(r, len, 3);
            return .{ .pair = pair };
        },
        Code.int_seq => {
            const start = try expectInt(r);
            const end = try expectInt(r);
            const step = try expectInt(r);
            try skipRest(r, len, 4);
            return .{ .int_seq = .{ .start = start, .end = end, .step = step } };
        },
        Code.regex => {
            const pattern = try expectString(allocator, r);
            errdefer allocator.free(pattern);
            try skipRest(r, len, 2);
            return .{ .regex = pattern };
        },
        Code.class => {
            const ref = try expectNameRef(allocator, r);
            errdefer freeRef(allocator, ref);
            try skipRest(r, len, 3);
            return .{ .class_ref = ref };
        },
        Code.type_alias => {
            const ref = try expectNameRef(allocator, r);
            errdefer freeRef(allocator, ref);
            try skipRest(r, len, 3);
            return .{ .type_alias = ref };
        },
        Code.bytes => {
            const payload = try decodeValue(allocator, r);
            if (payload != .bytes) {
                var doomed = payload;
                doomed.deinit(allocator);
                return error.InvalidPkl;
            }
            errdefer allocator.free(payload.bytes);
            try skipRest(r, len, 2);
            return payload;
        },
        Code.function => return error.FunctionValue,
        else => return error.UnknownType,
    }
}

fn decodeObject(allocator: Allocator, r: *Reader, len: u32) Error!value.Value {
    if (len < 4) return error.InvalidPkl;
    var object = value.Object{
        .class_name = try expectString(allocator, r),
        .module_uri = undefined,
    };
    errdefer allocator.free(object.class_name);
    object.module_uri = try expectString(allocator, r);
    errdefer allocator.free(object.module_uri);

    const members = try msgpack.readHeader(r);
    if (members != .array) return error.InvalidPkl;

    var elements: std.ArrayList(value.Value) = .empty;
    errdefer {
        for (elements.items) |*element| element.deinit(allocator);
        elements.deinit(allocator);
    }
    var entries: std.ArrayList(value.Entry) = .empty;
    errdefer {
        for (entries.items) |*entry| {
            entry.key.deinit(allocator);
            entry.value.deinit(allocator);
        }
        entries.deinit(allocator);
    }
    errdefer {
        var it = object.properties.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        object.properties.deinit(allocator);
    }

    for (0..members.array) |_| try readMember(allocator, r, &object, &entries, &elements);
    object.entries = try entries.toOwnedSlice(allocator);
    errdefer {
        for (object.entries) |*entry| {
            entry.key.deinit(allocator);
            entry.value.deinit(allocator);
        }
        allocator.free(object.entries);
        object.entries = &.{};
    }
    object.elements = try elements.toOwnedSlice(allocator);
    errdefer {
        for (object.elements) |*element| element.deinit(allocator);
        allocator.free(object.elements);
        object.elements = &.{};
    }
    try skipRest(r, len, 4);
    return .{ .object = object };
}

fn readMember(
    allocator: Allocator,
    r: *Reader,
    object: *value.Object,
    entries: *std.ArrayList(value.Entry),
    elements: *std.ArrayList(value.Value),
) Error!void {
    const header = try msgpack.readHeader(r);
    if (header != .array or header.array == 0) return error.InvalidPkl;
    const code = try expectInt(r);
    switch (code) {
        Code.property => {
            var owned_name: ?[]u8 = try expectString(allocator, r);
            errdefer if (owned_name) |name| allocator.free(name);
            var member = try decodeValue(allocator, r);
            errdefer member.deinit(allocator);
            const gop = try object.properties.getOrPut(allocator, owned_name.?);
            if (gop.found_existing) {
                allocator.free(owned_name.?);
                gop.value_ptr.deinit(allocator);
            }
            owned_name = null;
            gop.value_ptr.* = member;
            member = .null;
            try skipRest(r, header.array, 3);
        },
        Code.entry => {
            var entry = value.Entry{
                .key = try decodeValue(allocator, r),
                .value = .null,
            };
            errdefer entry.key.deinit(allocator);
            entry.value = try decodeValue(allocator, r);
            errdefer entry.value.deinit(allocator);
            try entries.append(allocator, entry);
            entry = .{ .key = .null, .value = .null };
            try skipRest(r, header.array, 3);
        },
        Code.element => {
            const index = try expectInt(r);
            if (index < 0) return error.InvalidPkl;
            var member = try decodeValue(allocator, r);
            errdefer member.deinit(allocator);
            const at: usize = @intCast(index);
            while (elements.items.len <= at) try elements.append(allocator, .null);
            elements.items[at].deinit(allocator);
            elements.items[at] = member;
            member = .null;
            try skipRest(r, header.array, 3);
        },
        else => return error.UnknownType,
    }
}

fn decodeList(allocator: Allocator, r: *Reader) Error![]value.Value {
    const header = try msgpack.readHeader(r);
    if (header != .array) return error.InvalidPkl;
    const items = try allocator.alloc(value.Value, header.array);
    var filled: usize = 0;
    errdefer {
        for (items[0..filled]) |*item| item.deinit(allocator);
        allocator.free(items);
    }
    for (items) |*item| {
        item.* = try decodeValue(allocator, r);
        filled += 1;
    }
    return items;
}

fn decodeMap(allocator: Allocator, r: *Reader) Error!value.Value {
    const header = try msgpack.readHeader(r);
    if (header != .map) return error.InvalidPkl;
    const entries = try allocator.alloc(value.Entry, header.map);
    var filled: usize = 0;
    errdefer {
        for (entries[0..filled]) |*entry| {
            entry.key.deinit(allocator);
            entry.value.deinit(allocator);
        }
        allocator.free(entries);
    }
    for (entries) |*entry| {
        entry.key = try decodeValue(allocator, r);
        entry.value = try decodeValue(allocator, r);
        filled += 1;
    }
    return .{ .map = entries };
}

fn expectInt(r: *Reader) Error!i64 {
    const header = try msgpack.readHeader(r);
    return switch (header) {
        .int => |n| n,
        else => error.InvalidPkl,
    };
}

fn expectNumber(r: *Reader) Error!f64 {
    const header = try msgpack.readHeader(r);
    return switch (header) {
        .float => |n| n,
        .int => |n| @floatFromInt(n),
        else => error.InvalidPkl,
    };
}

fn expectString(allocator: Allocator, r: *Reader) Error![]u8 {
    const header = try msgpack.readHeader(r);
    return switch (header) {
        .string => |len| msgpack.readCounted(r, allocator, len),
        else => error.InvalidPkl,
    };
}

fn expectNameRef(allocator: Allocator, r: *Reader) Error!value.NameRef {
    const name = try expectString(allocator, r);
    errdefer allocator.free(name);
    return .{
        .name = name,
        .module_uri = try expectString(allocator, r),
    };
}

fn skipRest(r: *Reader, len: u32, used: u32) Error!void {
    if (len < used) return error.InvalidPkl;
    for (0..len - used) |_| try msgpack.skip(r);
}

fn freeList(allocator: Allocator, items: []value.Value) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

fn freeRef(allocator: Allocator, ref: value.NameRef) void {
    allocator.free(ref.name);
    allocator.free(ref.module_uri);
}

test "decodes primitives and a typed object" {
    const gpa = std.testing.allocator;
    var enc = msgpack.Encoder.init(gpa);
    defer enc.deinit();

    try enc.array(4);
    try enc.int(0x01);
    try enc.string("config");
    try enc.string("file:///config.pkl");
    try enc.array(6);

    try enc.array(3);
    try enc.int(0x10);
    try enc.string("name");
    try enc.string("svc");

    try enc.array(3);
    try enc.int(0x10);
    try enc.string("replicas");
    try enc.int(3);

    try enc.array(3);
    try enc.int(0x10);
    try enc.string("timeout");
    try enc.array(3);
    try enc.int(0x07);
    try enc.float(30);
    try enc.string("s");

    try enc.array(3);
    try enc.int(0x10);
    try enc.string("tags");
    try enc.array(2);
    try enc.int(0x05);
    try enc.array(2);
    try enc.string("a");
    try enc.string("b");

    try enc.array(3);
    try enc.int(0x10);
    try enc.string("coords");
    try enc.array(3);
    try enc.int(0x09);
    try enc.int(1);
    try enc.int(2);

    try enc.array(3);
    try enc.int(0x11);
    try enc.string("env");
    try enc.string("prod");

    var decoded = try decode(gpa, enc.bytes.items);
    defer decoded.deinit(gpa);

    try std.testing.expectEqualStrings("config", decoded.object.class_name);
    try std.testing.expectEqualStrings("svc", decoded.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 3), decoded.get("replicas").?.int);
    const timeout = decoded.get("timeout").?.duration;
    try std.testing.expectEqual(@as(f64, 30), timeout.toUnit(.s));
    try std.testing.expectEqual(@as(usize, 2), decoded.get("tags").?.list.len);
    const pair = decoded.get("coords").?.pair;
    try std.testing.expectEqual(@as(i64, 1), pair.first.int);
    try std.testing.expectEqual(@as(i64, 2), pair.second.int);
    try std.testing.expectEqualStrings("prod", decoded.object.entries[0].value.string);
}
