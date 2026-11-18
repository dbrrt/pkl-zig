//! Runtime values decoded from Pkl's binary encoding.
//!
//! Strings, slices, and maps inside a `Value` are owned by the allocator that
//! produced them. `deinit` releases that tree. Values returned by an
//! `Evaluator` live in a `Decoded` arena instead; free the `Decoded`, not the
//! nested `Value`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const DurationUnit = enum { ns, us, ms, s, min, h, d };
pub const DataSizeUnit = enum { b, kb, mb, gb, tb, pb, kib, mib, gib, tib, pib };

pub const Duration = struct {
    value: f64,
    unit: DurationUnit,

    pub fn toUnit(self: Duration, unit: DurationUnit) f64 {
        return self.value * nanos(self.unit) / nanos(unit);
    }

    pub fn toNanos(self: Duration) f64 {
        return self.value * nanos(self.unit);
    }

    fn nanos(unit: DurationUnit) f64 {
        return switch (unit) {
            .ns => 1,
            .us => 1e3,
            .ms => 1e6,
            .s => 1e9,
            .min => 60e9,
            .h => 3600e9,
            .d => 86400e9,
        };
    }
};

pub const DataSize = struct {
    value: f64,
    unit: DataSizeUnit,

    pub fn toUnit(self: DataSize, unit: DataSizeUnit) f64 {
        return self.value * bytes(self.unit) / bytes(unit);
    }

    pub fn toBytes(self: DataSize) f64 {
        return self.value * bytes(self.unit);
    }

    fn bytes(unit: DataSizeUnit) f64 {
        return switch (unit) {
            .b => 1,
            .kb => 1e3,
            .mb => 1e6,
            .gb => 1e9,
            .tb => 1e12,
            .pb => 1e15,
            .kib => 1024,
            .mib => 1024 * 1024,
            .gib => 1024 * 1024 * 1024,
            .tib => 1024.0 * 1024 * 1024 * 1024,
            .pib => 1024.0 * 1024 * 1024 * 1024 * 1024,
        };
    }
};

pub const IntSeq = struct {
    start: i64,
    end: i64,
    step: i64,

    pub const Iterator = struct {
        seq: IntSeq,
        cursor: i64,
        done: bool,

        pub fn next(self: *Iterator) ?i64 {
            if (self.done or self.seq.step == 0) {
                self.done = true;
                return null;
            }
            if (self.seq.step > 0 and self.cursor > self.seq.end) {
                self.done = true;
                return null;
            }
            if (self.seq.step < 0 and self.cursor < self.seq.end) {
                self.done = true;
                return null;
            }
            const current = self.cursor;
            self.cursor = std.math.add(i64, self.cursor, self.seq.step) catch blk: {
                self.done = true;
                break :blk self.cursor;
            };
            return current;
        }
    };

    pub fn iterator(self: IntSeq) Iterator {
        return .{ .seq = self, .cursor = self.start, .done = false };
    }

    pub fn toOwnedSlice(self: IntSeq, gpa: Allocator) Allocator.Error![]i64 {
        var list: std.ArrayList(i64) = .empty;
        errdefer list.deinit(gpa);
        var it = self.iterator();
        while (it.next()) |n| try list.append(gpa, n);
        return list.toOwnedSlice(gpa);
    }
};

pub const NameRef = struct {
    name: []u8,
    module_uri: []u8,
};

pub const Entry = struct {
    key: Value,
    value: Value,
};

pub const Pair = struct {
    first: Value,
    second: Value,
};

pub const Object = struct {
    class_name: []u8,
    module_uri: []u8,
    properties: std.StringArrayHashMapUnmanaged(Value) = .empty,
    entries: []Entry = &.{},
    elements: []Value = &.{},

    pub fn get(self: Object, name: []const u8) ?Value {
        return self.properties.get(name);
    }

    pub fn getPtr(self: *const Object, name: []const u8) ?*const Value {
        return self.properties.getPtr(name);
    }
};

pub const Value = union(enum) {
    null,
    boolean: bool,
    int: i64,
    float: f64,
    string: []u8,
    bytes: []u8,
    list: []Value,
    set: []Value,
    map: []Entry,
    object: Object,
    duration: Duration,
    data_size: DataSize,
    pair: *Pair,
    int_seq: IntSeq,
    regex: []u8,
    class_ref: NameRef,
    type_alias: NameRef,

    pub fn deinit(self: *Value, gpa: Allocator) void {
        switch (self.*) {
            .null, .boolean, .int, .float, .duration, .data_size, .int_seq => {},
            .string, .regex => |s| gpa.free(s),
            .bytes => |b| gpa.free(b),
            .list, .set => |items| {
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
            .pair => |pair| {
                pair.first.deinit(gpa);
                pair.second.deinit(gpa);
                gpa.destroy(pair);
            },
            .class_ref, .type_alias => |ref| {
                gpa.free(ref.name);
                gpa.free(ref.module_uri);
            },
            .object => |*object| {
                gpa.free(object.class_name);
                gpa.free(object.module_uri);
                var it = object.properties.iterator();
                while (it.next()) |entry| {
                    gpa.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(gpa);
                }
                object.properties.deinit(gpa);
                for (object.entries) |*entry| {
                    entry.key.deinit(gpa);
                    entry.value.deinit(gpa);
                }
                gpa.free(object.entries);
                for (object.elements) |*element| element.deinit(gpa);
                gpa.free(object.elements);
            },
        }
    }

    pub fn clone(self: Value, gpa: Allocator) Allocator.Error!Value {
        return switch (self) {
            .null => .null,
            .boolean => |b| .{ .boolean = b },
            .int => |n| .{ .int = n },
            .float => |n| .{ .float = n },
            .duration => |d| .{ .duration = d },
            .data_size => |d| .{ .data_size = d },
            .int_seq => |s| .{ .int_seq = s },
            .string => |s| .{ .string = try gpa.dupe(u8, s) },
            .regex => |s| .{ .regex = try gpa.dupe(u8, s) },
            .bytes => |b| .{ .bytes = try gpa.dupe(u8, b) },
            .list => |items| .{ .list = try cloneSlice(gpa, items) },
            .set => |items| .{ .set = try cloneSlice(gpa, items) },
            .map => |entries| blk: {
                const out = try gpa.alloc(Entry, entries.len);
                var i: usize = 0;
                errdefer {
                    for (out[0..i]) |*entry| {
                        entry.key.deinit(gpa);
                        entry.value.deinit(gpa);
                    }
                    gpa.free(out);
                }
                for (entries) |entry| {
                    out[i] = .{
                        .key = try entry.key.clone(gpa),
                        .value = try entry.value.clone(gpa),
                    };
                    i += 1;
                }
                break :blk .{ .map = out };
            },
            .pair => |pair| blk: {
                const out = try gpa.create(Pair);
                errdefer gpa.destroy(out);
                out.first = try pair.first.clone(gpa);
                errdefer out.first.deinit(gpa);
                out.second = try pair.second.clone(gpa);
                break :blk .{ .pair = out };
            },
            .class_ref => |ref| .{ .class_ref = try cloneRef(gpa, ref) },
            .type_alias => |ref| .{ .type_alias = try cloneRef(gpa, ref) },
            .object => |object| .{ .object = try cloneObject(gpa, object) },
        };
    }

    pub fn get(self: Value, name: []const u8) ?Value {
        return switch (self) {
            .object => |object| object.get(name),
            else => null,
        };
    }

    pub fn text(self: Value) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }
};

fn cloneSlice(gpa: Allocator, items: []const Value) Allocator.Error![]Value {
    const out = try gpa.alloc(Value, items.len);
    var i: usize = 0;
    errdefer {
        for (out[0..i]) |*item| item.deinit(gpa);
        gpa.free(out);
    }
    for (items) |item| {
        out[i] = try item.clone(gpa);
        i += 1;
    }
    return out;
}

fn cloneRef(gpa: Allocator, ref: NameRef) Allocator.Error!NameRef {
    const name = try gpa.dupe(u8, ref.name);
    errdefer gpa.free(name);
    return .{ .name = name, .module_uri = try gpa.dupe(u8, ref.module_uri) };
}

fn cloneObject(gpa: Allocator, object: Object) Allocator.Error!Object {
    const class_name = try gpa.dupe(u8, object.class_name);
    errdefer gpa.free(class_name);
    const module_uri = try gpa.dupe(u8, object.module_uri);
    errdefer gpa.free(module_uri);

    var properties: std.StringArrayHashMapUnmanaged(Value) = .empty;
    errdefer {
        var it = properties.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            entry.value_ptr.deinit(gpa);
        }
        properties.deinit(gpa);
    }
    var it = object.properties.iterator();
    while (it.next()) |entry| {
        const key = try gpa.dupe(u8, entry.key_ptr.*);
        const cloned = try entry.value_ptr.clone(gpa);
        properties.put(gpa, key, cloned) catch |err| {
            gpa.free(key);
            var doomed = cloned;
            doomed.deinit(gpa);
            return err;
        };
    }

    const entries = try gpa.alloc(Entry, object.entries.len);
    var entry_count: usize = 0;
    errdefer {
        for (entries[0..entry_count]) |*entry| {
            entry.key.deinit(gpa);
            entry.value.deinit(gpa);
        }
        gpa.free(entries);
    }
    for (object.entries) |entry| {
        const key = try entry.key.clone(gpa);
        errdefer key.deinit(gpa);
        const cloned_value = try entry.value.clone(gpa);
        entries[entry_count] = .{ .key = key, .value = cloned_value };
        entry_count += 1;
    }

    const elements = try cloneSlice(gpa, object.elements);
    return .{
        .class_name = class_name,
        .module_uri = module_uri,
        .properties = properties,
        .entries = entries,
        .elements = elements,
    };
}

pub fn parseDurationUnit(text: []const u8) error{UnknownUnit}!DurationUnit {
    return std.meta.stringToEnum(DurationUnit, text) orelse error.UnknownUnit;
}

pub fn parseDataSizeUnit(text: []const u8) error{UnknownUnit}!DataSizeUnit {
    return std.meta.stringToEnum(DataSizeUnit, text) orelse error.UnknownUnit;
}

test "duration and data size convert between units" {
    const timeout = Duration{ .value = 30, .unit = .s };
    try std.testing.expectEqual(@as(f64, 0.5), timeout.toUnit(.min));
    try std.testing.expectEqual(@as(f64, 30e9), timeout.toNanos());

    const size = DataSize{ .value = 10, .unit = .mib };
    try std.testing.expectEqual(@as(f64, 10), size.toUnit(.mib));
    try std.testing.expectEqual(@as(f64, 10 * 1024 * 1024), size.toBytes());
}

test "int sequence iterates inclusive bounds" {
    const seq = IntSeq{ .start = 1, .end = 10, .step = 2 };
    const values = try seq.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(values);
    try std.testing.expectEqualSlices(i64, &.{ 1, 3, 5, 7, 9 }, values);
}
