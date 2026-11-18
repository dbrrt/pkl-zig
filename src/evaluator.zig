//! Evaluator that speaks Pkl's message-passing API to a `pkl server` child process.
//! Requests are synchronous: a read, list, or log message that arrives while a
//! request is in flight is handled before the response is delivered.
//! Reader callbacks must not call back into the same evaluator.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const binary = @import("binary.zig");
const msgpack = @import("msgpack.zig");
const source = @import("source.zig");
const value = @import("value.zig");

pub const ModuleSource = source.ModuleSource;
pub const textSource = source.textSource;
pub const textSourceUri = source.textSourceUri;
pub const uriSource = source.uriSource;
pub const fileUri = source.fileUri;

pub const Error = error{
    OutOfMemory,
    /// The `pkl` process, the protocol, or the call itself failed. See `diagnostic`.
    Binding,
    /// Pkl rejected the program. See `diagnostic`.
    Evaluation,
    Closed,
};

pub const Property = struct {
    name: []const u8,
    value: []const u8,
};

pub const PathElement = struct {
    name: []const u8,
    is_directory: bool,
};

pub const ResourceReader = struct {
    scheme: []const u8,
    has_hierarchical_uris: bool,
    is_globbable: bool,
    context: ?*anyopaque = null,
    /// Return resource bytes allocated with `gpa`. The evaluator frees them.
    read: *const fn (context: ?*anyopaque, uri: []const u8, gpa: Allocator) anyerror![]u8,
    /// Return elements allocated with `gpa`, including each `name`. The evaluator frees them.
    list: ?*const fn (context: ?*anyopaque, uri: []const u8, gpa: Allocator) anyerror![]PathElement = null,
};

pub const ModuleReader = struct {
    scheme: []const u8,
    has_hierarchical_uris: bool,
    is_globbable: bool,
    is_local: bool,
    context: ?*anyopaque = null,
    /// Return module source allocated with `gpa`. The evaluator frees it.
    read: *const fn (context: ?*anyopaque, uri: []const u8, gpa: Allocator) anyerror![]u8,
    list: ?*const fn (context: ?*anyopaque, uri: []const u8, gpa: Allocator) anyerror![]PathElement = null,
};

pub const Logger = struct {
    context: ?*anyopaque = null,
    /// `message` and `frame_uri` are valid only for the duration of the call.
    trace: *const fn (context: ?*anyopaque, message: []const u8, frame_uri: []const u8) void = noop,
    warn: *const fn (context: ?*anyopaque, message: []const u8, frame_uri: []const u8) void = noop,

    pub const silent: Logger = .{};

    fn noop(_: ?*anyopaque, _: []const u8, _: []const u8) void {}
};

pub const stderr_logger: Logger = .{
    .trace = logTrace,
    .warn = logWarn,
};

fn logTrace(_: ?*anyopaque, message: []const u8, frame_uri: []const u8) void {
    std.debug.print("pkl: trace: {s} ({s})\n", .{ message, frame_uri });
}

fn logWarn(_: ?*anyopaque, message: []const u8, frame_uri: []const u8) void {
    std.debug.print("pkl: warn: {s} ({s})\n", .{ message, frame_uri });
}

pub const Options = struct {
    allowed_modules: ?[]const []const u8 = null,
    allowed_resources: ?[]const []const u8 = null,
    properties: []const Property = &.{},
    /// `null` exposes the host environment. An empty slice exposes none.
    env: ?[]const Property = null,
    module_paths: []const []const u8 = &.{},
    timeout_seconds: ?i64 = null,
    root_dir: ?[]const u8 = null,
    cache_dir: ?[]const u8 = null,
    module_readers: []const ModuleReader = &.{},
    resource_readers: []const ResourceReader = &.{},
    logger: Logger = .{},
    output_format: ?[]const u8 = null,
    /// Executable used to spawn `pkl server`. `null` uses `PKL_EXECUTABLE` or `pkl`.
    command: ?[]const u8 = null,
    /// Inherit the child process stderr. Also enabled when `PKL_DEBUG` is non-empty.
    debug: bool = false,
};

pub const Decoded = struct {
    arena: *std.heap.ArenaAllocator,
    value: value.Value,

    pub fn deinit(self: *Decoded) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
        self.* = undefined;
    }
};

pub const Evaluator = struct {
    impl: *Impl,
    id: i64,
    owns_manager: bool,
    closed: bool = false,

    pub fn open(gpa: Allocator, io: Io, environ: std.process.Environ, options: Options) Error!Evaluator {
        var manager = try Manager.open(gpa, io, environ, options);
        errdefer manager.deinit();
        var ev = try manager.create(options, null);
        ev.owns_manager = true;
        manager.impl = null;
        return ev;
    }

    pub fn openProject(
        gpa: Allocator,
        io: Io,
        environ: std.process.Environ,
        project_dir: []const u8,
        options: Options,
    ) Error!Evaluator {
        var manager = try Manager.open(gpa, io, environ, options);
        errdefer manager.deinit();
        const impl = manager.impl.?;
        var loaded = try loadProject(impl, gpa, io, project_dir, options);
        defer loaded.deinit();
        var merged = options;
        applySettings(&merged, loaded.settings);
        const id = try impl.createEvaluator(merged, loaded.project);
        manager.impl = null;
        return .{ .impl = impl, .id = id, .owns_manager = true };
    }

    pub fn close(self: *Evaluator) void {
        if (self.closed) return;
        self.closed = true;
        if (!self.impl.closed) self.impl.closeEvaluator(self.id);
        if (self.owns_manager) self.impl.shutdown();
    }

    pub fn deinit(self: *Evaluator) void {
        const owns = self.owns_manager;
        const impl = self.impl;
        self.close();
        if (owns) impl.destroy();
    }

    pub fn diagnostic(self: *const Evaluator) []const u8 {
        return self.impl.diagnostic.items;
    }

    pub fn allocator(self: *const Evaluator) Allocator {
        return self.impl.gpa;
    }

    pub fn evaluateModule(self: *Evaluator, module: ModuleSource) Error!Decoded {
        return self.evaluateExpressionOpt(module, null);
    }

    pub fn evaluateExpression(self: *Evaluator, module: ModuleSource, expr: []const u8) Error!Decoded {
        return self.evaluateExpressionOpt(module, expr);
    }

    pub fn evaluateOutputText(self: *Evaluator, module: ModuleSource) Error![]u8 {
        var decoded = try self.evaluateExpression(module, "output.text");
        defer decoded.deinit();
        const text = switch (decoded.value) {
            .string => |s| s,
            else => {
                self.impl.setDiag("output.text was not a string");
                return error.Binding;
            },
        };
        return self.impl.gpa.dupe(u8, text) catch return error.OutOfMemory;
    }

    pub fn evaluateOutputJson(self: *Evaluator, module: ModuleSource) Error!std.json.Parsed(std.json.Value) {
        var decoded = try self.evaluateExpression(module, "new JsonRenderer {}.renderDocument(output.value)");
        defer decoded.deinit();
        const text = switch (decoded.value) {
            .string => |s| s,
            else => {
                self.impl.setDiag("JSON renderer did not return a string");
                return error.Binding;
            },
        };
        return std.json.parseFromSlice(std.json.Value, self.impl.gpa, text, .{}) catch |err| {
            self.impl.setDiagFmt("invalid JSON from Pkl: {s}", .{@errorName(err)});
            return error.Binding;
        };
    }

    /// Raw `pkl-binary` bytes, allocated with the evaluator's allocator.
    pub fn evaluateRaw(self: *Evaluator, module: ModuleSource, expr: ?[]const u8) Error![]u8 {
        try self.ensureOpen();
        return self.impl.evaluate(self.id, module, expr);
    }

    fn evaluateExpressionOpt(self: *Evaluator, module: ModuleSource, expr: ?[]const u8) Error!Decoded {
        const bytes = try self.evaluateRaw(module, expr);
        return self.impl.decodeResult(bytes);
    }

    fn ensureOpen(self: *Evaluator) Error!void {
        if (self.closed or self.impl.closed) return error.Closed;
    }
};

pub const Manager = struct {
    impl: ?*Impl,

    pub fn open(gpa: Allocator, io: Io, environ: std.process.Environ, options: Options) Error!Manager {
        const impl = gpa.create(Impl) catch return error.OutOfMemory;
        impl.* = .{
            .gpa = gpa,
            .io = io,
            .environ = environ,
            .child = undefined,
            .command = &.{},
        };
        impl.command = resolveCommand(gpa, environ, options.command) catch |err| {
            gpa.destroy(impl);
            return err;
        };
        impl.spawn(debugEnabled(gpa, environ, options)) catch |err| {
            gpa.free(impl.command);
            gpa.destroy(impl);
            return err;
        };
        return .{ .impl = impl };
    }

    pub fn deinit(self: *Manager) void {
        if (self.impl) |impl| {
            impl.shutdown();
            impl.destroy();
            self.impl = null;
        }
    }

    pub fn evaluator(self: *Manager, options: Options) Error!Evaluator {
        return self.create(options, null);
    }

    fn create(self: *Manager, options: Options, project: ?Project) Error!Evaluator {
        const impl = self.impl orelse return error.Closed;
        const id = try impl.createEvaluator(options, project);
        return .{ .impl = impl, .id = id, .owns_manager = false };
    }
};

const Hooks = struct {
    logger: Logger,
    module_readers: []ModuleReader,
    resource_readers: []ResourceReader,
};

const Dep = struct {
    name: []const u8,
    kind: enum { local, remote },
    package_uri: ?[]const u8 = null,
    project_file_uri: ?[]const u8 = null,
    sha256: ?[]const u8 = null,
    dependencies: []const Dep = &.{},
};

const Project = struct {
    project_file_uri: []const u8,
    dependencies: []const Dep = &.{},
};

const Settings = struct {
    properties: ?[]const Property = null,
    env: ?[]const Property = null,
    allowed_modules: ?[]const []const u8 = null,
    allowed_resources: ?[]const []const u8 = null,
    module_paths: ?[]const []const u8 = null,
    timeout_seconds: ?i64 = null,
    root_dir: ?[]const u8 = null,
    cache_dir: ?[]const u8 = null,
    no_cache: bool = false,
};

const Loaded = struct {
    gpa: Allocator,
    project_file_uri: []u8,
    decoded: ?Decoded = null,
    project: Project,
    settings: Settings = .{},

    fn deinit(self: *Loaded) void {
        self.gpa.free(self.project_file_uri);
        if (self.decoded) |*decoded| decoded.deinit();
    }
};

pub const Impl = struct {
    gpa: Allocator,
    io: Io,
    environ: std.process.Environ,
    child: std.process.Child,
    command: []u8,
    spawned: bool = false,
    stdout_buf: [8192]u8 = undefined,
    reader: std.Io.File.Reader = undefined,
    reader_ready: bool = false,
    next_request_id: i64 = 1,
    evaluators: std.AutoHashMapUnmanaged(i64, Hooks) = .empty,
    pending_hooks: ?Hooks = null,
    diagnostic: std.ArrayList(u8) = .empty,
    closed: bool = false,

    fn destroy(self: *Impl) void {
        self.shutdown();
        var it = self.evaluators.iterator();
        while (it.next()) |entry| self.freeHooks(entry.value_ptr.*);
        self.evaluators.deinit(self.gpa);
        self.diagnostic.deinit(self.gpa);
        if (self.command.len > 0) self.gpa.free(self.command);
        self.gpa.destroy(self);
    }

    fn shutdown(self: *Impl) void {
        if (self.closed) return;
        self.closed = true;
        if (self.spawned) self.child.kill(self.io);
    }

    fn spawn(self: *Impl, debug: bool) Error!void {
        self.child = std.process.spawn(self.io, .{
            .argv = &.{ self.command, "server" },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = if (debug) .inherit else .ignore,
        }) catch |err| {
            self.setDiagFmt(
                "failed to start pkl (command: \"{s}\"): {s}. Install the pkl CLI or set PKL_EXECUTABLE.",
                .{ self.command, @errorName(err) },
            );
            return error.Binding;
        };
        self.spawned = true;
    }

    fn createEvaluator(self: *Impl, options: Options, project: ?Project) Error!i64 {
        if (self.closed) return error.Closed;
        const request_id = self.nextId();
        const hooks = try self.makeHooks(options);
        errdefer self.freeHooks(hooks);
        self.pending_hooks = hooks;
        defer self.pending_hooks = null;

        const bytes = try self.createMessage(request_id, options, project);
        defer self.gpa.free(bytes);
        var response = try self.roundTrip(bytes, 0x21);
        defer response.deinit(self.gpa);
        const payload = messageBody(response) orelse {
            self.setDiag("pkl returned a malformed create-evaluator response");
            return error.Binding;
        };
        if (errorText(payload)) |text| {
            self.setDiag(text);
            return error.Binding;
        }
        const id = fieldInt(payload, "evaluatorId") orelse {
            self.setDiag("pkl returned no evaluator id");
            return error.Binding;
        };
        self.evaluators.put(self.gpa, id, hooks) catch return error.OutOfMemory;
        return id;
    }

    fn evaluate(self: *Impl, id: i64, module: ModuleSource, expr: ?[]const u8) Error![]u8 {
        if (self.closed) return error.Closed;
        if (self.evaluators.get(id) == null) {
            self.setDiag("unknown or closed evaluator");
            return error.Binding;
        }
        const request_id = self.nextId();
        const bytes = try self.evaluateMessage(request_id, id, module, expr);
        defer self.gpa.free(bytes);
        var response = try self.roundTrip(bytes, 0x24);
        defer response.deinit(self.gpa);
        const payload = messageBody(response) orelse {
            self.setDiag("pkl returned a malformed evaluate response");
            return error.Binding;
        };
        if (errorText(payload)) |text| {
            self.setDiag(text);
            return error.Evaluation;
        }
        const result = payload.get("result") orelse {
            self.setDiag("pkl returned an empty evaluation result");
            return error.Binding;
        };
        const raw: []const u8 = switch (result) {
            .binary => |b| b,
            .string => |s| s,
            else => {
                self.setDiag("pkl evaluation result was not binary");
                return error.Binding;
            },
        };
        return self.gpa.dupe(u8, raw) catch return error.OutOfMemory;
    }

    fn decodeResult(self: *Impl, bytes: []u8) Error!Decoded {
        defer self.gpa.free(bytes);
        const arena = self.gpa.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
        arena.* = .init(self.gpa);
        errdefer {
            arena.deinit();
            self.gpa.destroy(arena);
        }
        const decoded = binary.decode(arena.allocator(), bytes) catch |err| {
            switch (err) {
                error.FunctionValue => self.setDiag("cannot decode a Pkl function value; functions cannot cross the binding boundary"),
                error.UnknownType => self.setDiag("unknown Pkl binary type code"),
                error.UnknownUnit => self.setDiag("unknown Pkl duration or data-size unit"),
                else => self.setDiagFmt("invalid Pkl binary ({s})", .{@errorName(err)}),
            }
            return error.Binding;
        };
        return .{ .arena = arena, .value = decoded };
    }

    fn closeEvaluator(self: *Impl, id: i64) void {
        if (self.evaluators.get(id)) |hooks| {
            _ = self.evaluators.remove(id);
            self.freeHooks(hooks);
        }
        const bytes = self.closeMessage(id) catch return;
        defer self.gpa.free(bytes);
        self.writeAll(bytes) catch {};
    }

    fn roundTrip(self: *Impl, bytes: []const u8, expect: i64) Error!msgpack.Value {
        try self.writeAll(bytes);
        while (true) {
            var msg = try self.readMessage();
            const code = messageCode(msg) orelse {
                msg.deinit(self.gpa);
                self.setDiag("pkl sent a malformed message");
                return error.Binding;
            };
            if (code == expect) return msg;
            self.dispatch(&msg) catch |err| {
                msg.deinit(self.gpa);
                return err;
            };
            msg.deinit(self.gpa);
        }
    }

    fn dispatch(self: *Impl, msg: *msgpack.Value) Error!void {
        const code = messageCode(msg.*) orelse return;
        switch (code) {
            0x25 => self.onLog(msg.*),
            0x26 => try self.onReadResource(msg.*),
            0x28 => try self.onReadModule(msg.*),
            0x2a => try self.onList(msg.*, false),
            0x2c => try self.onList(msg.*, true),
            else => {},
        }
    }

    fn onLog(self: *Impl, msg: msgpack.Value) void {
        const payload = messageBody(msg) orelse return;
        const id = fieldInt(payload, "evaluatorId") orelse return;
        const hooks = self.hooksFor(id) orelse return;
        const level = fieldInt(payload, "level") orelse 1;
        const message = fieldString(payload, "message") orelse "";
        const frame = fieldString(payload, "frameUri") orelse "";
        if (level == 0) {
            hooks.logger.trace(hooks.logger.context, message, frame);
        } else {
            hooks.logger.warn(hooks.logger.context, message, frame);
        }
    }

    fn onReadResource(self: *Impl, msg: msgpack.Value) Error!void {
        const payload = messageBody(msg) orelse return;
        const request_id = fieldInt(payload, "requestId") orelse return;
        const evaluator_id = fieldInt(payload, "evaluatorId") orelse return;
        const uri = fieldString(payload, "uri") orelse "";
        const reader = self.resourceReader(evaluator_id, uri);
        if (reader == null) {
            return self.sendResource(request_id, evaluator_id, null, "no resource reader registered for this scheme");
        }
        const bytes = reader.?.read(reader.?.context, uri, self.gpa) catch |err| {
            const text = std.fmt.allocPrint(self.gpa, "{s}", .{@errorName(err)}) catch return error.OutOfMemory;
            defer self.gpa.free(text);
            return self.sendResource(request_id, evaluator_id, null, text);
        };
        defer self.gpa.free(bytes);
        return self.sendResource(request_id, evaluator_id, bytes, null);
    }

    fn onReadModule(self: *Impl, msg: msgpack.Value) Error!void {
        const payload = messageBody(msg) orelse return;
        const request_id = fieldInt(payload, "requestId") orelse return;
        const evaluator_id = fieldInt(payload, "evaluatorId") orelse return;
        const uri = fieldString(payload, "uri") orelse "";
        const reader = self.moduleReader(evaluator_id, uri);
        if (reader == null) {
            return self.sendModule(request_id, evaluator_id, null, "no module reader registered for this scheme");
        }
        const text = reader.?.read(reader.?.context, uri, self.gpa) catch |err| {
            const rendered = std.fmt.allocPrint(self.gpa, "{s}", .{@errorName(err)}) catch return error.OutOfMemory;
            defer self.gpa.free(rendered);
            return self.sendModule(request_id, evaluator_id, null, rendered);
        };
        defer self.gpa.free(text);
        return self.sendModule(request_id, evaluator_id, text, null);
    }

    fn onList(self: *Impl, msg: msgpack.Value, modules: bool) Error!void {
        const payload = messageBody(msg) orelse return;
        const request_id = fieldInt(payload, "requestId") orelse return;
        const evaluator_id = fieldInt(payload, "evaluatorId") orelse return;
        const uri = fieldString(payload, "uri") orelse "";
        const response_code: i64 = if (modules) 0x2d else 0x2b;
        if (modules) {
            const reader = self.moduleReader(evaluator_id, uri);
            if (reader == null or reader.?.list == null) {
                return self.sendList(response_code, request_id, evaluator_id, null, "reader does not support listing");
            }
            const elements = reader.?.list.?(reader.?.context, uri, self.gpa) catch |err| {
                const text = std.fmt.allocPrint(self.gpa, "{s}", .{@errorName(err)}) catch return error.OutOfMemory;
                defer self.gpa.free(text);
                return self.sendList(response_code, request_id, evaluator_id, null, text);
            };
            defer freeElements(self.gpa, elements);
            return self.sendList(response_code, request_id, evaluator_id, elements, null);
        }
        const reader = self.resourceReader(evaluator_id, uri);
        if (reader == null or reader.?.list == null) {
            return self.sendList(response_code, request_id, evaluator_id, null, "reader does not support listing");
        }
        const elements = reader.?.list.?(reader.?.context, uri, self.gpa) catch |err| {
            const text = std.fmt.allocPrint(self.gpa, "{s}", .{@errorName(err)}) catch return error.OutOfMemory;
            defer self.gpa.free(text);
            return self.sendList(response_code, request_id, evaluator_id, null, text);
        };
        defer freeElements(self.gpa, elements);
        return self.sendList(response_code, request_id, evaluator_id, elements, null);
    }

    fn sendResource(self: *Impl, request_id: i64, evaluator_id: i64, contents: ?[]const u8, err_text: ?[]const u8) Error!void {
        var enc = msgpack.Encoder.init(self.gpa);
        defer enc.deinit();
        var n: usize = 2;
        if (contents != null) n += 1;
        if (err_text != null) n += 1;
        try self.put(&enc, 0x27, n);
        try enc.string("requestId");
        try enc.int(request_id);
        try enc.string("evaluatorId");
        try enc.int(evaluator_id);
        if (contents) |bytes| {
            try enc.string("contents");
            try enc.binary(bytes);
        }
        if (err_text) |text| {
            try enc.string("error");
            try enc.string(text);
        }
        return self.writeAll(enc.bytes.items);
    }

    fn sendModule(self: *Impl, request_id: i64, evaluator_id: i64, contents: ?[]const u8, err_text: ?[]const u8) Error!void {
        var enc = msgpack.Encoder.init(self.gpa);
        defer enc.deinit();
        var n: usize = 2;
        if (contents != null) n += 1;
        if (err_text != null) n += 1;
        try self.put(&enc, 0x29, n);
        try enc.string("requestId");
        try enc.int(request_id);
        try enc.string("evaluatorId");
        try enc.int(evaluator_id);
        if (contents) |text| {
            try enc.string("contents");
            try enc.string(text);
        }
        if (err_text) |text| {
            try enc.string("error");
            try enc.string(text);
        }
        return self.writeAll(enc.bytes.items);
    }

    fn sendList(
        self: *Impl,
        code: i64,
        request_id: i64,
        evaluator_id: i64,
        elements: ?[]const PathElement,
        err_text: ?[]const u8,
    ) Error!void {
        var enc = msgpack.Encoder.init(self.gpa);
        defer enc.deinit();
        var n: usize = 2;
        if (elements != null) n += 1;
        if (err_text != null) n += 1;
        try self.put(&enc, code, n);
        try enc.string("requestId");
        try enc.int(request_id);
        try enc.string("evaluatorId");
        try enc.int(evaluator_id);
        if (elements) |items| {
            try enc.string("pathElements");
            try enc.array(items.len);
            for (items) |item| {
                try enc.map(2);
                try enc.string("name");
                try enc.string(item.name);
                try enc.string("isDirectory");
                try enc.boolean(item.is_directory);
            }
        }
        if (err_text) |text| {
            try enc.string("error");
            try enc.string(text);
        }
        return self.writeAll(enc.bytes.items);
    }

    fn put(self: *Impl, enc: *msgpack.Encoder, code: i64, fields: usize) Error!void {
        enc.array(2) catch return error.OutOfMemory;
        enc.int(code) catch return error.OutOfMemory;
        enc.map(fields) catch return error.OutOfMemory;
        _ = self;
    }

    fn createMessage(self: *Impl, request_id: i64, options: Options, project: ?Project) Error![]u8 {
        const modules = try ensureRepl(self.gpa, options.allowed_modules orelse &default_modules);
        defer if (modules.owned) |owned| self.gpa.free(owned);
        const resources = options.allowed_resources orelse &default_resources;

        var env_map = if (options.env == null) std.process.Environ.createMap(self.environ, self.gpa) catch return error.OutOfMemory else null;
        defer if (env_map) |*map| map.deinit();

        var n: usize = 4; // requestId, allowedModules, allowedResources, env
        if (options.properties.len > 0) n += 1;
        if (options.module_paths.len > 0) n += 1;
        if (options.timeout_seconds != null) n += 1;
        if (options.root_dir != null) n += 1;
        if (options.cache_dir != null) n += 1;
        if (options.output_format != null) n += 1;
        if (options.module_readers.len > 0) n += 1;
        if (options.resource_readers.len > 0) n += 1;
        if (project != null) n += 1;

        var enc = msgpack.Encoder.init(self.gpa);
        errdefer enc.deinit();
        try self.put(&enc, 0x20, n);
        try encField(&enc, "requestId");
        try encInt(&enc, request_id);
        try encStringArray(&enc, "allowedModules", modules.items);
        try encStringArray(&enc, "allowedResources", resources);
        try encField(&enc, "env");
        if (options.env) |pairs| {
            try encMap(&enc, pairs.len);
            for (pairs) |pair| {
                try encStr(&enc, pair.name);
                try encStr(&enc, pair.value);
            }
        } else {
            const map = &env_map.?;
            try encMap(&enc, map.count());
            var it = map.iterator();
            while (it.next()) |entry| {
                try encStr(&enc, entry.key_ptr.*);
                try encStr(&enc, entry.value_ptr.*);
            }
        }
        if (options.properties.len > 0) {
            try encField(&enc, "properties");
            try encMap(&enc, options.properties.len);
            for (options.properties) |pair| {
                try encStr(&enc, pair.name);
                try encStr(&enc, pair.value);
            }
        }
        if (options.module_paths.len > 0) try encStringArray(&enc, "modulePaths", options.module_paths);
        if (options.timeout_seconds) |seconds| {
            try encField(&enc, "timeoutSeconds");
            try encInt(&enc, seconds);
        }
        if (options.root_dir) |dir| {
            try encField(&enc, "rootDir");
            try encStr(&enc, dir);
        }
        if (options.cache_dir) |dir| {
            try encField(&enc, "cacheDir");
            try encStr(&enc, dir);
        }
        if (options.output_format) |format| {
            try encField(&enc, "outputFormat");
            try encStr(&enc, format);
        }
        if (options.module_readers.len > 0) {
            try encField(&enc, "clientModuleReaders");
            try encArray(&enc, options.module_readers.len);
            for (options.module_readers) |reader| {
                try encMap(&enc, 4);
                try encStr(&enc, "scheme");
                try encStr(&enc, reader.scheme);
                try encStr(&enc, "hasHierarchicalUris");
                try encBool(&enc, reader.has_hierarchical_uris);
                try encStr(&enc, "isGlobbable");
                try encBool(&enc, reader.is_globbable);
                try encStr(&enc, "isLocal");
                try encBool(&enc, reader.is_local);
            }
        }
        if (options.resource_readers.len > 0) {
            try encField(&enc, "clientResourceReaders");
            try encArray(&enc, options.resource_readers.len);
            for (options.resource_readers) |reader| {
                try encMap(&enc, 3);
                try encStr(&enc, "scheme");
                try encStr(&enc, reader.scheme);
                try encStr(&enc, "hasHierarchicalUris");
                try encBool(&enc, reader.has_hierarchical_uris);
                try encStr(&enc, "isGlobbable");
                try encBool(&enc, reader.is_globbable);
            }
        }
        if (project) |proj| {
            try encField(&enc, "project");
            try encodeProject(&enc, proj);
        }
        return enc.toOwnedSlice() catch return error.OutOfMemory;
    }

    fn evaluateMessage(self: *Impl, request_id: i64, evaluator_id: i64, module: ModuleSource, expr: ?[]const u8) Error![]u8 {
        var n: usize = 3;
        if (module.text != null) n += 1;
        if (expr != null) n += 1;
        var enc = msgpack.Encoder.init(self.gpa);
        errdefer enc.deinit();
        try self.put(&enc, 0x23, n);
        try encField(&enc, "requestId");
        try encInt(&enc, request_id);
        try encField(&enc, "evaluatorId");
        try encInt(&enc, evaluator_id);
        try encField(&enc, "moduleUri");
        try encStr(&enc, module.uri);
        if (module.text) |text| {
            try encField(&enc, "moduleText");
            try encStr(&enc, text);
        }
        if (expr) |expression| {
            try encField(&enc, "expr");
            try encStr(&enc, expression);
        }
        return enc.toOwnedSlice() catch return error.OutOfMemory;
    }

    fn closeMessage(self: *Impl, evaluator_id: i64) Error![]u8 {
        var enc = msgpack.Encoder.init(self.gpa);
        errdefer enc.deinit();
        try self.put(&enc, 0x22, 1);
        try encField(&enc, "evaluatorId");
        try encInt(&enc, evaluator_id);
        return enc.toOwnedSlice() catch return error.OutOfMemory;
    }

    fn readMessage(self: *Impl) Error!msgpack.Value {
        return msgpack.decode(self.stdoutReader(), self.gpa) catch |err| {
            self.setDiagFmt("error reading from pkl server: {s}", .{@errorName(err)});
            return error.Binding;
        };
    }

    fn stdoutReader(self: *Impl) *std.Io.Reader {
        if (!self.reader_ready) {
            self.reader = self.child.stdout.?.readerStreaming(self.io, &self.stdout_buf);
            self.reader_ready = true;
        }
        return &self.reader.interface;
    }

    fn writeAll(self: *Impl, bytes: []const u8) Error!void {
        const stdin = self.child.stdin orelse {
            self.setDiag("pkl stdin is closed");
            return error.Binding;
        };
        stdin.writeStreamingAll(self.io, bytes) catch |err| {
            self.setDiagFmt("error writing to pkl server: {s}", .{@errorName(err)});
            return error.Binding;
        };
    }

    fn makeHooks(self: *Impl, options: Options) Error!Hooks {
        const modules = self.gpa.dupe(ModuleReader, options.module_readers) catch return error.OutOfMemory;
        errdefer self.gpa.free(modules);
        const resources = self.gpa.dupe(ResourceReader, options.resource_readers) catch return error.OutOfMemory;
        return .{
            .logger = options.logger,
            .module_readers = modules,
            .resource_readers = resources,
        };
    }

    fn freeHooks(self: *Impl, hooks: Hooks) void {
        self.gpa.free(hooks.module_readers);
        self.gpa.free(hooks.resource_readers);
    }

    fn hooksFor(self: *Impl, id: i64) ?Hooks {
        if (self.evaluators.get(id)) |hooks| return hooks;
        return self.pending_hooks;
    }

    fn resourceReader(self: *Impl, id: i64, uri: []const u8) ?ResourceReader {
        const hooks = self.hooksFor(id) orelse return null;
        const scheme = schemeOf(uri);
        for (hooks.resource_readers) |reader| {
            if (std.mem.eql(u8, reader.scheme, scheme)) return reader;
        }
        return null;
    }

    fn moduleReader(self: *Impl, id: i64, uri: []const u8) ?ModuleReader {
        const hooks = self.hooksFor(id) orelse return null;
        const scheme = schemeOf(uri);
        for (hooks.module_readers) |reader| {
            if (std.mem.eql(u8, reader.scheme, scheme)) return reader;
        }
        return null;
    }

    fn nextId(self: *Impl) i64 {
        const id = self.next_request_id;
        self.next_request_id += 1;
        return id;
    }

    fn setDiag(self: *Impl, text: []const u8) void {
        const copy = self.gpa.dupe(u8, text) catch return;
        self.diagnostic.deinit(self.gpa);
        self.diagnostic = .fromOwnedSlice(copy);
    }

    fn setDiagFmt(self: *Impl, comptime fmt: []const u8, args: anytype) void {
        const copy = std.fmt.allocPrint(self.gpa, fmt, args) catch return;
        self.diagnostic.deinit(self.gpa);
        self.diagnostic = .fromOwnedSlice(copy);
    }
};

const default_modules = [_][]const u8{
    "pkl:",
    "repl:",
    "file:",
    "modulepath:",
    "https:",
    "package:",
    "projectpackage:",
};

const default_resources = [_][]const u8{
    "env:",
    "prop:",
    "file:",
    "modulepath:",
    "https:",
    "package:",
    "projectpackage:",
    "pkl:",
};

const StringList = struct {
    items: []const []const u8,
    owned: ?[]const []const u8 = null,
};

fn ensureRepl(gpa: Allocator, items: []const []const u8) Error!StringList {
    for (items) |item| {
        if (std.mem.eql(u8, item, "repl:text") or std.mem.eql(u8, item, "repl:")) {
            return .{ .items = items };
        }
    }
    const owned = gpa.alloc([]const u8, items.len + 1) catch return error.OutOfMemory;
    @memcpy(owned[0..items.len], items);
    owned[items.len] = "repl:text";
    return .{ .items = owned, .owned = owned };
}

fn resolveCommand(gpa: Allocator, environ: std.process.Environ, requested: ?[]const u8) Error![]u8 {
    if (requested) |command| return gpa.dupe(u8, command) catch return error.OutOfMemory;
    if (std.process.Environ.getAlloc(environ, gpa, "PKL_EXECUTABLE")) |command| {
        return command;
    } else |err| switch (err) {
        error.EnvironmentVariableMissing => {},
        else => return error.OutOfMemory,
    }
    return gpa.dupe(u8, "pkl") catch return error.OutOfMemory;
}

fn debugEnabled(gpa: Allocator, environ: std.process.Environ, options: Options) bool {
    if (options.debug) return true;
    const flag = std.process.Environ.getAlloc(environ, gpa, "PKL_DEBUG") catch return false;
    defer gpa.free(flag);
    return flag.len != 0 and !std.mem.eql(u8, flag, "0");
}

fn applySettings(options: *Options, settings: Settings) void {
    if (options.properties.len == 0) {
        if (settings.properties) |properties| options.properties = properties;
    }
    if (options.env == null) options.env = settings.env;
    if (options.allowed_modules == null) options.allowed_modules = settings.allowed_modules;
    if (options.allowed_resources == null) options.allowed_resources = settings.allowed_resources;
    if (options.module_paths.len == 0) {
        if (settings.module_paths) |paths| options.module_paths = paths;
    }
    if (options.timeout_seconds == null) options.timeout_seconds = settings.timeout_seconds;
    if (options.root_dir == null) options.root_dir = settings.root_dir;
    if (options.cache_dir == null) {
        if (settings.no_cache) {
            options.cache_dir = "";
        } else {
            options.cache_dir = settings.cache_dir;
        }
    }
}

fn loadProject(impl: *Impl, gpa: Allocator, io: Io, project_dir: []const u8, options: Options) Error!Loaded {
    const directory = Io.Dir.cwd().realPathFileAlloc(io, project_dir, gpa) catch |err| {
        impl.setDiagFmt("cannot resolve project directory: {s}", .{@errorName(err)});
        return error.Binding;
    };
    defer gpa.free(directory);
    const project_path = std.fs.path.join(gpa, &.{ directory, "PklProject" }) catch return error.OutOfMemory;
    defer gpa.free(project_path);
    const uri = source.fileUri(gpa, io, project_path) catch |err| {
        impl.setDiagFmt("cannot open PklProject: {s}", .{@errorName(err)});
        return error.Binding;
    };
    var loaded = Loaded{
        .gpa = gpa,
        .project_file_uri = uri,
        .project = .{ .project_file_uri = uri },
    };
    errdefer loaded.deinit();

    const id = try impl.createEvaluator(options, null);
    var temp = Evaluator{ .impl = impl, .id = id, .owns_manager = false };
    defer temp.close();

    var decoded = temp.evaluateModule(.{ .uri = uri }) catch |err| switch (err) {
        error.Evaluation => {
            impl.diagnostic.clearRetainingCapacity();
            return loaded;
        },
        else => return err,
    };
    loaded.decoded = decoded;
    const alloc = loaded.decoded.?.arena.allocator();
    loaded.project = readProject(alloc, loaded.decoded.?.value, uri) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => .{ .project_file_uri = uri },
    };
    loaded.settings = readSettings(alloc, loaded.decoded.?.value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => .{},
    };
    return loaded;
}

fn readProject(alloc: Allocator, root: value.Value, fallback_uri: []const u8) Error!Project {
    const object = switch (root) {
        .object => |object| object,
        else => return .{ .project_file_uri = fallback_uri },
    };
    const uri = if (object.get("projectFileUri")) |field| field.text() orelse fallback_uri else fallback_uri;
    const dependencies = object.get("dependencies") orelse return .{ .project_file_uri = uri };
    return .{
        .project_file_uri = uri,
        .dependencies = try readDeps(alloc, dependencies),
    };
}

fn readDeps(alloc: Allocator, decoded: value.Value) Error![]Dep {
    if (decoded == .null) return &.{};
    const entries = switch (decoded) {
        .map => |items| items,
        else => return error.Binding,
    };
    const out = alloc.alloc(Dep, entries.len) catch return error.OutOfMemory;
    for (entries, 0..) |entry, i| {
        const name = entry.key.text() orelse return error.Binding;
        out[i] = try readDep(alloc, name, entry.value);
    }
    return out;
}

fn readDep(alloc: Allocator, name: []const u8, decoded: value.Value) Error!Dep {
    const object = switch (decoded) {
        .object => |object| object,
        else => return .{ .name = name, .kind = .remote },
    };
    if (isRemote(object)) {
        return .{
            .name = name,
            .kind = .remote,
            .package_uri = if (object.get("uri")) |field| field.text() else null,
            .sha256 = checksum(object),
        };
    }
    const nested = if (object.get("dependencies")) |field| try readDeps(alloc, field) else &.{};
    return .{
        .name = name,
        .kind = .local,
        .package_uri = packageUri(object),
        .project_file_uri = if (object.get("projectFileUri")) |field| field.text() else null,
        .dependencies = nested,
    };
}

fn isRemote(object: value.Object) bool {
    if (std.mem.indexOf(u8, object.class_name, "RemoteDependency") != null) return true;
    if (object.get("projectFileUri") != null) return false;
    return object.get("uri") != null;
}

fn packageUri(object: value.Object) ?[]const u8 {
    const package = object.get("package") orelse return null;
    if (package != .object) return null;
    const uri = package.object.get("uri") orelse return null;
    return uri.text();
}

fn checksum(object: value.Object) ?[]const u8 {
    const sums = object.get("checksums") orelse return null;
    if (sums != .object) return null;
    const sha = sums.object.get("sha256") orelse return null;
    return sha.text();
}

fn readSettings(alloc: Allocator, root: value.Value) Error!Settings {
    const object = switch (root) {
        .object => |object| object,
        else => return .{},
    };
    const settings_value = object.get("evaluatorSettings") orelse return .{};
    if (settings_value != .object) return .{};
    const settings = settings_value.object;
    var out = Settings{};
    if (settings.get("externalProperties")) |field| {
        if (field != .null) out.properties = try propertiesFromMap(alloc, field);
    }
    if (settings.get("env")) |field| {
        if (field != .null) out.env = try propertiesFromMap(alloc, field);
    }
    if (settings.get("allowedModules")) |field| {
        if (field != .null) out.allowed_modules = try stringsFromList(alloc, field);
    }
    if (settings.get("allowedResources")) |field| {
        if (field != .null) out.allowed_resources = try stringsFromList(alloc, field);
    }
    if (settings.get("modulePath")) |field| {
        if (field != .null) out.module_paths = try stringsFromList(alloc, field);
    }
    if (settings.get("timeout")) |field| {
        if (field == .duration) out.timeout_seconds = durationSeconds(field.duration);
    }
    if (settings.get("moduleCacheDir")) |field| {
        if (field.text()) |text| {
            if (text.len > 0) out.cache_dir = text;
        }
    }
    if (settings.get("rootDir")) |field| {
        if (field.text()) |text| {
            if (text.len > 0) out.root_dir = text;
        }
    }
    if (settings.get("noCache")) |field| {
        if (field == .boolean) out.no_cache = field.boolean;
    }
    return out;
}

fn propertiesFromMap(alloc: Allocator, decoded: value.Value) Error![]Property {
    const entries = switch (decoded) {
        .map => |items| items,
        else => return error.Binding,
    };
    const out = alloc.alloc(Property, entries.len) catch return error.OutOfMemory;
    for (entries, out) |entry, *slot| {
        slot.* = .{
            .name = entry.key.text() orelse return error.Binding,
            .value = entry.value.text() orelse return error.Binding,
        };
    }
    return out;
}

fn stringsFromList(alloc: Allocator, decoded: value.Value) Error![]const []const u8 {
    const items = switch (decoded) {
        .list => |list| list,
        else => return error.Binding,
    };
    const out = alloc.alloc([]const u8, items.len) catch return error.OutOfMemory;
    for (items, out) |item, *slot| slot.* = item.text() orelse return error.Binding;
    return out;
}

fn durationSeconds(duration: value.Duration) i64 {
    const seconds = duration.toUnit(.s);
    if (seconds <= 0) return 0;
    return @intFromFloat(@floor(seconds));
}

fn encodeProject(enc: *msgpack.Encoder, project: Project) Error!void {
    try encMap(enc, 2);
    try encStr(enc, "projectFileUri");
    try encStr(enc, project.project_file_uri);
    try encStr(enc, "dependencies");
    try encMap(enc, project.dependencies.len);
    for (project.dependencies) |dep| {
        try encStr(enc, dep.name);
        try encodeDep(enc, dep);
    }
}

fn encodeDep(enc: *msgpack.Encoder, dep: Dep) Error!void {
    var n: usize = 1;
    if (dep.package_uri != null) n += 1;
    if (dep.project_file_uri != null) n += 1;
    if (dep.sha256 != null) n += 1;
    if (dep.dependencies.len > 0) n += 1;
    try encMap(enc, n);
    try encStr(enc, "type");
    try encStr(enc, if (dep.kind == .local) "local" else "remote");
    if (dep.package_uri) |uri| {
        try encStr(enc, "packageUri");
        try encStr(enc, uri);
    }
    if (dep.project_file_uri) |uri| {
        try encStr(enc, "projectFileUri");
        try encStr(enc, uri);
    }
    if (dep.sha256) |sum| {
        try encStr(enc, "checksums");
        try encMap(enc, 1);
        try encStr(enc, "sha256");
        try encStr(enc, sum);
    }
    if (dep.dependencies.len > 0) {
        try encStr(enc, "dependencies");
        try encMap(enc, dep.dependencies.len);
        for (dep.dependencies) |nested| {
            try encStr(enc, nested.name);
            try encodeDep(enc, nested);
        }
    }
}

fn messageCode(msg: msgpack.Value) ?i64 {
    const items = switch (msg) {
        .array => |array| array,
        else => return null,
    };
    if (items.len != 2) return null;
    return switch (items[0]) {
        .int => |n| n,
        else => null,
    };
}

fn messageBody(msg: msgpack.Value) ?msgpack.Value {
    return switch (msg) {
        .array => |array| if (array.len == 2) array[1] else null,
        else => null,
    };
}

fn fieldInt(payload: msgpack.Value, key: []const u8) ?i64 {
    const field = payload.get(key) orelse return null;
    return switch (field) {
        .int => |n| n,
        else => null,
    };
}

fn fieldString(payload: msgpack.Value, key: []const u8) ?[]const u8 {
    const field = payload.get(key) orelse return null;
    return switch (field) {
        .string => |s| s,
        else => null,
    };
}

fn errorText(payload: msgpack.Value) ?[]const u8 {
    const text = fieldString(payload, "error") orelse return null;
    if (text.len == 0) return null;
    return text;
}

fn schemeOf(uri: []const u8) []const u8 {
    const index = std.mem.indexOfScalar(u8, uri, ':') orelse return uri;
    return uri[0..index];
}

fn freeElements(gpa: Allocator, elements: []PathElement) void {
    for (elements) |element| gpa.free(element.name);
    gpa.free(elements);
}

fn encField(enc: *msgpack.Encoder, name: []const u8) Error!void {
    enc.string(name) catch return error.OutOfMemory;
}
fn encStr(enc: *msgpack.Encoder, text: []const u8) Error!void {
    enc.string(text) catch return error.OutOfMemory;
}
fn encInt(enc: *msgpack.Encoder, n: i64) Error!void {
    enc.int(n) catch return error.OutOfMemory;
}
fn encBool(enc: *msgpack.Encoder, bit: bool) Error!void {
    enc.boolean(bit) catch return error.OutOfMemory;
}
fn encMap(enc: *msgpack.Encoder, len: usize) Error!void {
    enc.map(len) catch return error.OutOfMemory;
}
fn encArray(enc: *msgpack.Encoder, len: usize) Error!void {
    enc.array(len) catch return error.OutOfMemory;
}
fn encStringArray(enc: *msgpack.Encoder, name: []const u8, items: []const []const u8) Error!void {
    try encField(enc, name);
    try encArray(enc, items.len);
    for (items) |item| try encStr(enc, item);
}
