//! Generate Zig structs from a Pkl module's schema.
//!
//! A small Pkl program reflects on the target module. The generator prints one
//! struct per class, plus `fromValue` and `deinit`. `fromValue` copies into the
//! allocator it is given.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const evaluator = @import("evaluator.zig");
const value = @import("value.zig");

pub const GenerateOptions = struct {
    /// Name used in the generated `@import`.
    import_name: []const u8 = "pkl",
    evaluator: evaluator.Options = .{},
};

pub const File = struct {
    filename: []u8,
    contents: []u8,
    gpa: Allocator,

    pub fn deinit(self: *File) void {
        self.gpa.free(self.filename);
        self.gpa.free(self.contents);
    }
};

const reflect_template =
    \\import "pkl:reflect" as reflect
    \\import "%TARGET%" as target
    \\
    \\local mod = reflect.Module(target)
    \\
    \\function typeDesc(t) =
    \\  let (cn = t.getClass().simpleName)
    \\    if (cn == "DeclaredType") new Dynamic { kind = "declared"; name = t.referent.reflectee.simpleName; args = t.typeArguments.map((a) -> typeDesc(a)) }
    \\    else if (cn == "NullableType") new Dynamic { kind = "nullable"; of = typeDesc(t.member) }
    \\    else if (cn == "UnionType") new Dynamic { kind = "union"; members = t.members.map((a) -> typeDesc(a)) }
    \\    else if (cn == "StringLiteralType") new Dynamic { kind = "stringLiteral"; value = t.value }
    \\    else if (cn == "NothingType") new Dynamic { kind = "nothing" }
    \\    else if (cn == "UnknownType") new Dynamic { kind = "unknown" }
    \\    else if (cn == "ModuleType") new Dynamic { kind = "module" }
    \\    else new Dynamic { kind = "other"; raw = cn }
    \\
    \\function propDesc(p) = new Dynamic { name = p.name; doc = p.docComment; type = typeDesc(p.type) }
    \\function classDesc(c) = new Dynamic { name = c.name; doc = c.docComment; properties = c.properties.values.map((p) -> propDesc(p)) }
    \\
    \\schema = new Dynamic {
    \\  moduleClass = classDesc(mod.moduleClass)
    \\  classes = mod.classes.values.map((c) -> classDesc(c))
    \\}
;

pub fn generate(
    gpa: Allocator,
    io: Io,
    environ: std.process.Environ,
    module_path: []const u8,
    options: GenerateOptions,
    diag: *std.ArrayList(u8),
) !File {
    const absolute = Io.Dir.cwd().realPathFileAlloc(io, module_path, gpa) catch |err| {
        try diag.appendSlice(gpa, "cannot resolve module path");
        return err;
    };
    defer gpa.free(absolute);
    const target_uri = try evaluator.fileUri(gpa, io, absolute);
    defer gpa.free(target_uri);
    const program = try reflectProgram(gpa, target_uri);
    defer gpa.free(program);
    const synthetic = try syntheticUri(gpa, target_uri);
    defer gpa.free(synthetic);

    var ev = try evaluator.Evaluator.open(gpa, io, environ, options.evaluator);
    defer ev.deinit();
    var decoded = ev.evaluateExpression(.{ .uri = synthetic, .text = program }, "schema") catch |err| {
        try diag.appendSlice(gpa, ev.diagnostic());
        return err;
    };
    defer decoded.deinit();

    const module_name = try pascal(gpa, std.fs.path.stem(absolute));
    defer gpa.free(module_name);
    const contents = try render(gpa, decoded.value, module_name, options.import_name);
    errdefer gpa.free(contents);
    const filename = try std.fmt.allocPrint(gpa, "{s}.zig", .{std.fs.path.basename(absolute)});
    return .{ .filename = filename, .contents = contents, .gpa = gpa };
}

fn reflectProgram(gpa: Allocator, target_uri: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var rest: []const u8 = reflect_template;
    while (std.mem.indexOf(u8, rest, "%TARGET%")) |index| {
        try out.appendSlice(gpa, rest[0..index]);
        try appendEscaped(gpa, &out, target_uri);
        rest = rest[index + "%TARGET%".len ..];
    }
    try out.appendSlice(gpa, rest);
    return out.toOwnedSlice(gpa);
}

fn appendEscaped(gpa: Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| {
        if (c == '\\' or c == '"') try out.append(gpa, '\\');
        try out.append(gpa, c);
    }
}

fn syntheticUri(gpa: Allocator, target: []const u8) ![]u8 {
    const slash = std.mem.lastIndexOfScalar(u8, target, '/') orelse return gpa.dupe(u8, "repl:text");
    return std.fmt.allocPrint(gpa, "{s}__pkl_gen__.pkl", .{target[0 .. slash + 1]});
}

fn render(gpa: Allocator, schema: value.Value, module_name: []const u8, import_name: []const u8) ![]u8 {
    const root = try asObject(schema);
    const module_class = try asObject(try required(root, "moduleClass"));
    const class_items = listOrEmpty(root.get("classes"));

    var type_name = try gpa.dupe(u8, module_name);
    defer gpa.free(type_name);
    for (class_items) |item| {
        const class = try asObject(item);
        const name = (try required(class, "name")).text() orelse return error.InvalidSchema;
        if (std.mem.eql(u8, name, type_name)) {
            const renamed = try std.fmt.allocPrint(gpa, "{s}Module", .{module_name});
            gpa.free(type_name);
            type_name = renamed;
            break;
        }
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "// Code generated by pkl-gen-zig. DO NOT EDIT.\n\nconst std = @import(\"std\");\nconst pkl = @import(\"");
    try out.appendSlice(gpa, import_name);
    try out.appendSlice(gpa, "\");\n\n");
    try writeClass(gpa, &out, type_name, module_class);
    for (class_items) |item| {
        const class = try asObject(item);
        const name = (try required(class, "name")).text() orelse return error.InvalidSchema;
        if (std.mem.eql(u8, name, type_name)) continue;
        try out.append(gpa, '\n');
        try writeClass(gpa, &out, name, class);
    }
    return out.toOwnedSlice(gpa);
}

fn writeClass(gpa: Allocator, out: *std.ArrayList(u8), name: []const u8, class: value.Object) !void {
    if (optionalString(class.get("doc"))) |doc| try writeDoc(gpa, out, doc, "");
    try out.appendSlice(gpa, "pub const ");
    try writeIdent(gpa, out, name);
    try out.appendSlice(gpa, " = struct {\n");

    const props = listOrEmpty(class.get("properties"));
    for (props) |prop| {
        const object = try asObject(prop);
        const prop_name = (try required(object, "name")).text() orelse return error.InvalidSchema;
        const prop_type = try required(object, "type");
        if (try stringLiteralUnion(gpa, prop_type)) |members| {
            defer gpa.free(members);
            const enum_name = try pascal(gpa, prop_name);
            defer gpa.free(enum_name);
            try out.appendSlice(gpa, "    pub const ");
            try writeIdent(gpa, out, enum_name);
            try out.appendSlice(gpa, " = enum { ");
            for (members, 0..) |member, i| {
                if (i != 0) try out.appendSlice(gpa, ", ");
                try writeIdent(gpa, out, member);
            }
            try out.appendSlice(gpa, " };\n");
        }
    }

    for (props) |prop| {
        const object = try asObject(prop);
        const prop_name = (try required(object, "name")).text() orelse return error.InvalidSchema;
        const prop_type = try required(object, "type");
        if (optionalString(object.get("doc"))) |doc| try writeDoc(gpa, out, doc, "    ");
        try out.appendSlice(gpa, "    ");
        try writeIdent(gpa, out, prop_name);
        try out.appendSlice(gpa, ": ");
        try writeType(gpa, out, prop_type, prop_name);
        try out.appendSlice(gpa, ",\n");
    }

    try out.appendSlice(gpa, "\n    pub fn fromValue(gpa: std.mem.Allocator, decoded: pkl.Value) !");
    try writeIdent(gpa, out, name);
    try out.appendSlice(gpa, " {\n        const obj = try pkl.typed.asObject(decoded);\n        return .{\n");
    for (props) |prop| {
        const object = try asObject(prop);
        const prop_name = (try required(object, "name")).text() orelse return error.InvalidSchema;
        const prop_type = try required(object, "type");
        try out.appendSlice(gpa, "            .");
        try writeIdent(gpa, out, prop_name);
        try out.appendSlice(gpa, " = ");
        try writeDecode(gpa, out, prop_type, prop_name);
        try out.appendSlice(gpa, ",\n");
    }
    try out.appendSlice(gpa, "        };\n    }\n\n    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {\n");
    for (props) |prop| {
        const object = try asObject(prop);
        const prop_name = (try required(object, "name")).text() orelse return error.InvalidSchema;
        try out.appendSlice(gpa, "        pkl.typed.free(gpa, &self.");
        try writeIdent(gpa, out, prop_name);
        try out.appendSlice(gpa, ");\n");
    }
    try out.appendSlice(gpa, "    }\n};\n");
}

fn writeDecode(gpa: Allocator, out: *std.ArrayList(u8), type_value: value.Value, prop: []const u8) !void {
    const kind = try kindOf(type_value);
    if (std.mem.eql(u8, kind, "nullable")) {
        const inner = try required(try asObject(type_value), "of");
        if (try declaredCallback(inner)) |callback| {
            try out.appendSlice(gpa, "try pkl.typed.optional(");
            try writeType(gpa, out, inner, prop);
            try out.appendSlice(gpa, ", gpa, ");
            try writeFieldExpr(gpa, out, prop);
            try out.appendSlice(gpa, ", ");
            try out.appendSlice(gpa, callback);
            try out.append(gpa, ')');
            return;
        }
        try out.appendSlice(gpa, "if (");
        try writeFieldExpr(gpa, out, prop);
        try out.appendSlice(gpa, " == .null) null else ");
        try writeDecode(gpa, out, inner, prop);
        return;
    }
    if (try stringLiteralUnion(gpa, type_value)) |members| {
        gpa.free(members);
        const enum_name = try pascal(gpa, prop);
        defer gpa.free(enum_name);
        try out.appendSlice(gpa, "try pkl.typed.asEnum(");
        try writeIdent(gpa, out, enum_name);
        try out.appendSlice(gpa, ", ");
        try writeFieldExpr(gpa, out, prop);
        try out.append(gpa, ')');
        return;
    }
    if (std.mem.eql(u8, kind, "declared")) {
        const info = try inspectDeclared(type_value);
        switch (info.kind) {
            .scalar => {
                if (declaredCallback(type_value) catch null) |callback| {
                    try out.appendSlice(gpa, "try ");
                    try out.appendSlice(gpa, callback);
                    try out.appendSlice(gpa, "(gpa, ");
                    try writeFieldExpr(gpa, out, prop);
                    try out.append(gpa, ')');
                    return;
                }
                try out.appendSlice(gpa, "try ");
                try writeIdent(gpa, out, info.name);
                try out.appendSlice(gpa, ".fromValue(gpa, ");
                try writeFieldExpr(gpa, out, prop);
                try out.append(gpa, ')');
                return;
            },
            .list => {
                try out.appendSlice(gpa, "try pkl.typed.list(");
                try writeType(gpa, out, info.args[0], prop);
                try out.appendSlice(gpa, ", gpa, ");
                try writeFieldExpr(gpa, out, prop);
                try out.appendSlice(gpa, ", ");
                try writeCallback(gpa, out, info.args[0]);
                try out.append(gpa, ')');
                return;
            },
            .map, .pair => {
                const fn_name = if (info.kind == .map) "pkl.typed.map" else "pkl.typed.pair";
                try out.appendSlice(gpa, "try ");
                try out.appendSlice(gpa, fn_name);
                try out.append(gpa, '(');
                try writeType(gpa, out, info.args[0], prop);
                try out.appendSlice(gpa, ", ");
                try writeType(gpa, out, info.args[1], prop);
                try out.appendSlice(gpa, ", gpa, ");
                try writeFieldExpr(gpa, out, prop);
                try out.appendSlice(gpa, ", ");
                try writeCallback(gpa, out, info.args[0]);
                try out.appendSlice(gpa, ", ");
                try writeCallback(gpa, out, info.args[1]);
                try out.append(gpa, ')');
                return;
            },
        }
    }
    try out.appendSlice(gpa, "try pkl.typed.clone(gpa, ");
    try writeFieldExpr(gpa, out, prop);
    try out.append(gpa, ')');
}

fn writeCallback(gpa: Allocator, out: *std.ArrayList(u8), type_value: value.Value) !void {
    if (declaredCallback(type_value) catch null) |callback| {
        try out.appendSlice(gpa, callback);
        return;
    }
    const kind = kindOf(type_value) catch {
        try out.appendSlice(gpa, "pkl.typed.clone");
        return;
    };
    if (std.mem.eql(u8, kind, "declared")) {
        const info = try inspectDeclared(type_value);
        if (info.kind == .scalar) {
            try writeIdent(gpa, out, info.name);
            try out.appendSlice(gpa, ".fromValue");
            return;
        }
    }
    try out.appendSlice(gpa, "pkl.typed.clone");
}

fn writeType(gpa: Allocator, out: *std.ArrayList(u8), type_value: value.Value, prop: []const u8) !void {
    const kind = try kindOf(type_value);
    if (std.mem.eql(u8, kind, "nullable")) {
        try out.append(gpa, '?');
        try writeType(gpa, out, try required(try asObject(type_value), "of"), prop);
        return;
    }
    if (try stringLiteralUnion(gpa, type_value)) |members| {
        gpa.free(members);
        const enum_name = try pascal(gpa, prop);
        defer gpa.free(enum_name);
        try writeIdent(gpa, out, enum_name);
        return;
    }
    if (!std.mem.eql(u8, kind, "declared")) {
        try out.appendSlice(gpa, "pkl.Value");
        return;
    }
    const info = try inspectDeclared(type_value);
    switch (info.kind) {
        .scalar => {
            if (zigPrimitive(info.name)) |primitive| {
                try out.appendSlice(gpa, primitive);
            } else {
                try writeIdent(gpa, out, info.name);
            }
        },
        .list => {
            try out.appendSlice(gpa, "[]");
            try writeType(gpa, out, info.args[0], prop);
        },
        .map => {
            try out.appendSlice(gpa, "pkl.typed.Entries(");
            try writeType(gpa, out, info.args[0], prop);
            try out.appendSlice(gpa, ", ");
            try writeType(gpa, out, info.args[1], prop);
            try out.append(gpa, ')');
        },
        .pair => {
            try out.appendSlice(gpa, "pkl.typed.PairOf(");
            try writeType(gpa, out, info.args[0], prop);
            try out.appendSlice(gpa, ", ");
            try writeType(gpa, out, info.args[1], prop);
            try out.append(gpa, ')');
        },
    }
}

const DeclaredKind = enum { scalar, list, map, pair };
const Declared = struct {
    name: []const u8,
    args: []const value.Value,
    kind: DeclaredKind,
};

fn inspectDeclared(type_value: value.Value) !Declared {
    const object = try asObject(type_value);
    const name = (try required(object, "name")).text() orelse return error.InvalidSchema;
    const args = listOrEmpty(object.get("args"));
    if (eql(name, "List") or eql(name, "Listing") or eql(name, "Set") or eql(name, "Collection")) {
        if (args.len < 1) return error.InvalidSchema;
        return .{ .name = name, .args = args, .kind = .list };
    }
    if (eql(name, "Map") or eql(name, "Mapping")) {
        if (args.len < 2) return error.InvalidSchema;
        return .{ .name = name, .args = args, .kind = .map };
    }
    if (eql(name, "Pair")) {
        if (args.len < 2) return error.InvalidSchema;
        return .{ .name = name, .args = args, .kind = .pair };
    }
    return .{ .name = name, .args = args, .kind = .scalar };
}

fn zigPrimitive(name: []const u8) ?[]const u8 {
    if (eql(name, "String") or eql(name, "Char") or eql(name, "Bytes")) return "[]u8";
    if (eql(name, "Int") or eql(name, "Int8") or eql(name, "Int16") or eql(name, "Int32") or
        eql(name, "UInt") or eql(name, "UInt8") or eql(name, "UInt16") or eql(name, "UInt32"))
        return "i64";
    if (eql(name, "Float")) return "f64";
    if (eql(name, "Boolean")) return "bool";
    if (eql(name, "Duration")) return "pkl.Duration";
    if (eql(name, "DataSize")) return "pkl.DataSize";
    if (eql(name, "IntSeq")) return "pkl.IntSeq";
    if (eql(name, "Any") or eql(name, "Object") or eql(name, "Dynamic") or eql(name, "Number")) return "pkl.Value";
    return null;
}

fn declaredCallback(type_value: value.Value) !?[]const u8 {
    const kind = try kindOf(type_value);
    if (!eql(kind, "declared")) return null;
    const info = try inspectDeclared(type_value);
    if (info.kind != .scalar) return null;
    const name = info.name;
    if (eql(name, "String") or eql(name, "Char")) return "pkl.typed.dupeString";
    if (eql(name, "Bytes")) return "pkl.typed.dupeBytes";
    if (eql(name, "Int") or eql(name, "Int8") or eql(name, "Int16") or eql(name, "Int32") or
        eql(name, "UInt") or eql(name, "UInt8") or eql(name, "UInt16") or eql(name, "UInt32"))
        return "pkl.typed.asInt";
    if (eql(name, "Float")) return "pkl.typed.asFloat";
    if (eql(name, "Boolean")) return "pkl.typed.asBool";
    if (eql(name, "Duration")) return "pkl.typed.asDuration";
    if (eql(name, "DataSize")) return "pkl.typed.asDataSize";
    if (eql(name, "IntSeq")) return "pkl.typed.asIntSeq";
    if (eql(name, "Any") or eql(name, "Object") or eql(name, "Dynamic") or eql(name, "Number")) return "pkl.typed.clone";
    return null;
}

fn stringLiteralUnion(gpa: Allocator, type_value: value.Value) !?[]const []const u8 {
    const kind = kindOf(type_value) catch return null;
    if (!eql(kind, "union")) return null;
    const members = listOrEmpty((try asObject(type_value)).get("members"));
    if (members.len == 0) return null;
    for (members) |member| {
        const member_kind = kindOf(member) catch return null;
        if (!eql(member_kind, "stringLiteral")) return null;
    }
    const out = try gpa.alloc([]const u8, members.len);
    errdefer gpa.free(out);
    for (members, out) |member, *slot| {
        slot.* = (try required(try asObject(member), "value")).text() orelse return error.InvalidSchema;
    }
    return out;
}

fn writeFieldExpr(gpa: Allocator, out: *std.ArrayList(u8), prop: []const u8) !void {
    try out.appendSlice(gpa, "try pkl.typed.field(obj, \"");
    try appendEscaped(gpa, out, prop);
    try out.appendSlice(gpa, "\")");
}

fn writeDoc(gpa: Allocator, out: *std.ArrayList(u8), doc: []const u8, indent: []const u8) !void {
    var lines = std.mem.splitScalar(u8, doc, '\n');
    while (lines.next()) |line| {
        try out.appendSlice(gpa, indent);
        try out.appendSlice(gpa, "/// ");
        var rest = line;
        while (std.mem.indexOf(u8, rest, "*/")) |index| {
            try out.appendSlice(gpa, rest[0..index]);
            try out.appendSlice(gpa, "* /");
            rest = rest[index + 2 ..];
        }
        try out.appendSlice(gpa, rest);
        try out.append(gpa, '\n');
    }
}

fn writeIdent(gpa: Allocator, out: *std.ArrayList(u8), name: []const u8) !void {
    if (isIdent(name)) {
        try out.appendSlice(gpa, name);
        return;
    }
    try out.appendSlice(gpa, "@\"");
    for (name) |c| {
        if (c == '\\' or c == '"') try out.append(gpa, '\\');
        try out.append(gpa, c);
    }
    try out.append(gpa, '"');
}

fn isIdent(name: []const u8) bool {
    if (name.len == 0 or isKeyword(name)) return false;
    switch (name[0]) {
        'A'...'Z', 'a'...'z', '_' => {},
        else => return false,
    }
    for (name[1..]) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '_' => {},
        else => return false,
    };
    return true;
}

fn isKeyword(name: []const u8) bool {
    const keywords = [_][]const u8{
        "addrspace",     "align",    "allowzero", "and",           "anyframe",
        "anytype",       "asm",      "async",     "await",         "break",
        "callconv",      "catch",    "comptime",  "const",         "continue",
        "defer",         "else",     "enum",      "errdefer",      "error",
        "export",        "extern",   "fn",        "for",           "if",
        "inline",        "noalias",  "noinline",  "nosuspend",     "opaque",
        "or",            "orelse",   "packed",    "pub",           "resume",
        "return",        "linksection", "struct", "suspend",       "switch",
        "test",          "threadlocal", "try",    "union",         "unreachable",
        "usingnamespace", "var",     "volatile",  "while",         "true",
        "false",         "null",     "undefined",
    };
    for (keywords) |keyword| if (std.mem.eql(u8, keyword, name)) return true;
    return false;
}

fn pascal(gpa: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var upper = true;
    for (text) |c| {
        if (!std.ascii.isAlphanumeric(c)) {
            upper = true;
            continue;
        }
        try out.append(gpa, if (upper) std.ascii.toUpper(c) else c);
        upper = false;
    }
    if (out.items.len == 0) try out.appendSlice(gpa, "Module");
    if (isKeyword(out.items)) try out.append(gpa, '_');
    return out.toOwnedSlice(gpa);
}

fn asObject(decoded: value.Value) !value.Object {
    return switch (decoded) {
        .object => |object| object,
        else => error.InvalidSchema,
    };
}

fn required(object: value.Object, name: []const u8) !value.Value {
    return object.get(name) orelse error.InvalidSchema;
}

fn kindOf(decoded: value.Value) ![]const u8 {
    return (try required(try asObject(decoded), "kind")).text() orelse error.InvalidSchema;
}

fn listOrEmpty(decoded: ?value.Value) []const value.Value {
    const value_ = decoded orelse return &.{};
    return switch (value_) {
        .list => |items| items,
        else => &.{},
    };
}

fn optionalString(decoded: ?value.Value) ?[]const u8 {
    const text = (decoded orelse return null).text() orelse return null;
    if (text.len == 0) return null;
    return text;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
