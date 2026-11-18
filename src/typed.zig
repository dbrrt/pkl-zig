//! Helpers for turning a dynamic `Value` into ordinary Zig data.
//! Generated code and hand-written loaders share these.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value = @import("value.zig");

pub const Value = value.Value;
pub const Object = value.Object;
pub const Duration = value.Duration;
pub const DataSize = value.DataSize;
pub const IntSeq = value.IntSeq;

pub const Error = error{
    TypeMismatch,
    MissingField,
    OutOfMemory,
};

pub fn asObject(decoded: Value) error{TypeMismatch}!Object {
    return switch (decoded) {
        .object => |object| object,
        else => error.TypeMismatch,
    };
}

pub fn field(object: Object, name: []const u8) error{MissingField}!Value {
    return object.get(name) orelse error.MissingField;
}

pub fn dupeString(gpa: Allocator, decoded: Value) error{ TypeMismatch, OutOfMemory }![]u8 {
    return switch (decoded) {
        .string => |s| gpa.dupe(u8, s),
        else => error.TypeMismatch,
    };
}

pub fn asInt(_: Allocator, decoded: Value) error{TypeMismatch}!i64 {
    return switch (decoded) {
        .int => |n| n,
        else => error.TypeMismatch,
    };
}

pub fn asFloat(_: Allocator, decoded: Value) error{TypeMismatch}!f64 {
    return switch (decoded) {
        .float => |n| n,
        .int => |n| @floatFromInt(n),
        else => error.TypeMismatch,
    };
}

pub fn asBool(_: Allocator, decoded: Value) error{TypeMismatch}!bool {
    return switch (decoded) {
        .boolean => |b| b,
        else => error.TypeMismatch,
    };
}

pub fn asDuration(_: Allocator, decoded: Value) error{TypeMismatch}!Duration {
    return switch (decoded) {
        .duration => |d| d,
        else => error.TypeMismatch,
    };
}

pub fn asDataSize(_: Allocator, decoded: Value) error{TypeMismatch}!DataSize {
    return switch (decoded) {
        .data_size => |d| d,
        else => error.TypeMismatch,
    };
}

pub fn asIntSeq(_: Allocator, decoded: Value) error{TypeMismatch}!IntSeq {
    return switch (decoded) {
        .int_seq => |s| s,
        else => error.TypeMismatch,
    };
}

pub fn dupeBytes(gpa: Allocator, decoded: Value) error{ TypeMismatch, OutOfMemory }![]u8 {
    return switch (decoded) {
        .bytes => |b| gpa.dupe(u8, b),
        else => error.TypeMismatch,
    };
}

pub fn asEnum(comptime E: type, decoded: Value) error{TypeMismatch}!E {
    const text = switch (decoded) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };
    return std.meta.stringToEnum(E, text) orelse error.TypeMismatch;
}

pub fn clone(gpa: Allocator, decoded: Value) Allocator.Error!Value {
    return decoded.clone(gpa);
}

pub fn optional(comptime T: type, gpa: Allocator, decoded: Value, comptime decode_fn: anytype) !?T {
    if (decoded == .null) return null;
    return try decode_fn(gpa, decoded);
}

pub fn list(comptime T: type, gpa: Allocator, decoded: Value, comptime decode_fn: anytype) ![]T {
    const items = switch (decoded) {
        .list => |xs| xs,
        .set => |xs| xs,
        else => return error.TypeMismatch,
    };
    const out = try gpa.alloc(T, items.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |*item| free(gpa, item);
        gpa.free(out);
    }
    for (items) |item| {
        out[filled] = try decode_fn(gpa, item);
        filled += 1;
    }
    return out;
}

pub fn Entries(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        pub const Item = struct { key: K, value: V };
        items: []Item,

        pub fn deinit(self: *Self, gpa: Allocator) void {
            for (self.items) |*item| {
                free(gpa, &item.key);
                free(gpa, &item.value);
            }
            gpa.free(self.items);
        }

        pub fn get(self: Self, key: []const u8) ?V {
            if (!(K == []u8 or K == []const u8)) return null;
            for (self.items) |item| {
                if (std.mem.eql(u8, item.key, key)) return item.value;
            }
            return null;
        }
    };
}

pub fn map(
    comptime K: type,
    comptime V: type,
    gpa: Allocator,
    decoded: Value,
    comptime decode_key: anytype,
    comptime decode_val: anytype,
) !Entries(K, V) {
    const entries = switch (decoded) {
        .map => |xs| xs,
        else => return error.TypeMismatch,
    };
    const Map = Entries(K, V);
    const items = try gpa.alloc(Map.Item, entries.len);
    var filled: usize = 0;
    errdefer {
        for (items[0..filled]) |*item| {
            free(gpa, &item.key);
            free(gpa, &item.value);
        }
        gpa.free(items);
    }
    for (entries) |entry| {
        items[filled] = .{
            .key = try decode_key(gpa, entry.key),
            .value = try decode_val(gpa, entry.value),
        };
        filled += 1;
    }
    return .{ .items = items };
}

pub fn PairOf(comptime A: type, comptime B: type) type {
    return struct {
        first: A,
        second: B,

        pub fn deinit(self: *@This(), gpa: Allocator) void {
            free(gpa, &self.first);
            free(gpa, &self.second);
        }
    };
}

pub fn pair(
    comptime A: type,
    comptime B: type,
    gpa: Allocator,
    decoded: Value,
    comptime decode_first: anytype,
    comptime decode_second: anytype,
) !PairOf(A, B) {
    return switch (decoded) {
        .pair => |item| .{
            .first = try decode_first(gpa, item.first),
            .second = try decode_second(gpa, item.second),
        },
        else => error.TypeMismatch,
    };
}

/// Release memory owned by `ptr.*`. Structs with a `deinit(Allocator)` method
/// are forwarded to it. Slices are freed element-wise, except `[]u8`, which is
/// a string or byte buffer.
pub fn free(gpa: Allocator, ptr: anytype) void {
    freeTyped(@TypeOf(ptr.*), gpa, ptr);
}

fn freeTyped(comptime T: type, gpa: Allocator, ptr: *T) void {
    switch (@typeInfo(T)) {
        .pointer => |info| switch (info.size) {
            .slice => {
                if (info.child != u8) {
                    for (ptr.*) |*element| freeTyped(info.child, gpa, element);
                }
                gpa.free(ptr.*);
            },
            else => {},
        },
        .optional => |info| {
            if (ptr.*) |*payload| freeTyped(info.child, gpa, payload);
        },
        .@"union" => {
            if (T == Value) ptr.deinit(gpa);
        },
        .@"struct" => {
            if (T == Value) {
                ptr.deinit(gpa);
                return;
            }
            if (@hasDecl(T, "deinit")) ptr.deinit(gpa);
        },
        else => {},
    }
}
