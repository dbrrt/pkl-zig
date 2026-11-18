const std = @import("std");
const Io = std.Io;
const evaluator = @import("evaluator.zig");
const codegen = @import("codegen.zig");
const value = @import("value.zig");

const config_pkl =
    \\/// Application configuration.
    \\module config
    \\
    \\/// The service name.
    \\name: String = "svc"
    \\replicas: Int = 3
    \\enabled: Boolean = true
    \\ratio: Float = 0.5
    \\timeout: Duration = 30.s
    \\maxSize: DataSize = 10.mib
    \\tags: Listing<String> = new { "a"; "b"; "c" }
    \\labels: Mapping<String, String> = new { ["env"] = "prod" }
    \\ports: Set<Int> = Set(80, 443)
    \\coords: Pair<Int, Int> = Pair(1, 2)
    \\nickname: String? = null
    \\
    \\class Endpoint {
    \\  path: String
    \\  method: "GET"|"POST" = "GET"
    \\}
    \\
    \\endpoints: Listing<Endpoint> = new {
    \\  new { path = "/health" }
    \\  new { path = "/submit"; method = "POST" }
    \\}
;

fn pklCommand(gpa: std.mem.Allocator) ![]u8 {
    if (std.process.Environ.getAlloc(std.testing.environ, gpa, "PKL_EXECUTABLE")) |command| {
        return command;
    } else |_| {}
    return gpa.dupe(u8, "/tmp/pkl");
}

fn openEvaluator(options: evaluator.Options) !evaluator.Evaluator {
    const command = try pklCommand(std.testing.allocator);
    defer std.testing.allocator.free(command);
    var merged = options;
    merged.command = command;
    return evaluator.Evaluator.open(std.testing.allocator, std.testing.io, std.testing.environ, merged);
}

test "evaluateExpression decodes primitives" {
    var ev = try openEvaluator(.{});
    defer ev.deinit();

    var sum = try ev.evaluateExpression(evaluator.textSource("res = 1 + 2"), "res");
    defer sum.deinit();
    try std.testing.expectEqual(@as(i64, 3), sum.value.int);

    var text = try ev.evaluateExpression(evaluator.textSource("res = \"a\" + \"b\""), "res");
    defer text.deinit();
    try std.testing.expectEqualStrings("ab", text.value.string);

    var flag = try ev.evaluateExpression(evaluator.textSource("res = true"), "res");
    defer flag.deinit();
    try std.testing.expect(flag.value.boolean);
}

test "evaluateModule decodes a full module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.pkl", .data = config_pkl });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..dir_len], "config.pkl" });
    defer std.testing.allocator.free(path);
    const uri = try evaluator.fileUri(std.testing.allocator, std.testing.io, path);
    defer std.testing.allocator.free(uri);

    var ev = try openEvaluator(.{});
    defer ev.deinit();
    var decoded = ev.evaluateModule(.{ .uri = uri }) catch |err| {
        std.debug.print("pkl diagnostic:\n{s}\n", .{ev.diagnostic()});
        return err;
    };
    defer decoded.deinit();

    const cfg = decoded.value;
    try std.testing.expectEqualStrings("svc", cfg.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 3), cfg.get("replicas").?.int);
    try std.testing.expect(cfg.get("enabled").?.boolean);
    try std.testing.expectEqual(@as(f64, 0.5), cfg.get("ratio").?.float);
    try std.testing.expect(cfg.get("nickname").? == .null);
    try std.testing.expectEqual(@as(f64, 30), cfg.get("timeout").?.duration.toUnit(.s));
    try std.testing.expectEqual(@as(f64, 10), cfg.get("maxSize").?.data_size.toUnit(.mib));
    try std.testing.expectEqual(@as(usize, 3), cfg.get("tags").?.list.len);
    try std.testing.expectEqualStrings("prod", cfg.get("labels").?.map[0].value.string);
    try std.testing.expectEqual(@as(usize, 2), cfg.get("ports").?.set.len);
    try std.testing.expectEqual(@as(i64, 1), cfg.get("coords").?.pair.first.int);
    try std.testing.expectEqual(@as(i64, 2), cfg.get("coords").?.pair.second.int);

    const endpoints = cfg.get("endpoints").?.list;
    try std.testing.expectEqual(@as(usize, 2), endpoints.len);
    try std.testing.expectEqualStrings("/health", endpoints[0].get("path").?.string);
    try std.testing.expectEqualStrings("GET", endpoints[0].get("method").?.string);
    try std.testing.expectEqualStrings("POST", endpoints[1].get("method").?.string);
}

test "evaluateExpression navigates into the module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.pkl", .data = config_pkl });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..dir_len], "config.pkl" });
    defer std.testing.allocator.free(path);
    const uri = try evaluator.fileUri(std.testing.allocator, std.testing.io, path);
    defer std.testing.allocator.free(uri);

    var ev = try openEvaluator(.{});
    defer ev.deinit();
    var replicas = try ev.evaluateExpression(.{ .uri = uri }, "replicas");
    defer replicas.deinit();
    try std.testing.expectEqual(@as(i64, 3), replicas.value.int);

    var endpoint = try ev.evaluateExpression(.{ .uri = uri }, "endpoints[1].path");
    defer endpoint.deinit();
    try std.testing.expectEqualStrings("/submit", endpoint.value.string);
}

test "evaluateOutputText renders JSON" {
    var ev = try openEvaluator(.{ .output_format = "json" });
    defer ev.deinit();
    const text = try ev.evaluateOutputText(evaluator.textSource("x = 1\ny = \"hi\""));
    defer std.testing.allocator.free(text);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("x").?.integer);
    try std.testing.expectEqualStrings("hi", parsed.value.object.get("y").?.string);
}

test "evaluateOutputJson parses a rendered document" {
    var ev = try openEvaluator(.{});
    defer ev.deinit();
    const parsed = try ev.evaluateOutputJson(evaluator.textSource("a = new Listing { 1; 2; 3 }"));
    defer parsed.deinit();
    const items = parsed.value.object.get("a").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqual(@as(i64, 2), items[1].integer);
}

test "custom resource reader" {
    const reader = evaluator.ResourceReader{
        .scheme = "secret",
        .has_hierarchical_uris = false,
        .is_globbable = false,
        .read = struct {
            fn read(_: ?*anyopaque, uri: []const u8, gpa: std.mem.Allocator) anyerror![]u8 {
                return std.fmt.allocPrint(gpa, "value-for-{s}", .{uri["secret:".len..]});
            }
        }.read,
    };
    var ev = try openEvaluator(.{
        .resource_readers = &.{reader},
        .allowed_resources = &.{ "secret:", "repl:" },
    });
    defer ev.deinit();
    var decoded = ev.evaluateExpression(
        evaluator.textSource("res = read(\"secret:token\").text"),
        "res",
    ) catch |err| {
        std.debug.print("pkl diagnostic:\n{s}\n", .{ev.diagnostic()});
        return err;
    };
    defer decoded.deinit();
    try std.testing.expectEqualStrings("value-for-token", decoded.value.string);
}

test "evaluation error leaves the evaluator usable" {
    var ev = try openEvaluator(.{});
    defer ev.deinit();
    const failed = ev.evaluateExpression(evaluator.textSource("x = 1 / 0 as Int"), "x");
    try std.testing.expectError(error.Evaluation, failed);
    try std.testing.expect(ev.diagnostic().len > 0);

    var decoded = try ev.evaluateExpression(evaluator.textSource("y = 5"), "y");
    defer decoded.deinit();
    try std.testing.expectEqual(@as(i64, 5), decoded.value.int);
}

test "project evaluator applies external properties" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "PklProject",
        .data =
        \\amends "pkl:Project"
        \\
        \\evaluatorSettings {
        \\  externalProperties {
        \\    ["bird"] = "canary"
        \\  }
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "PklProject.deps.json",
        .data =
        \\{
        \\  "schemaVersion": 1,
        \\  "resolvedDependencies": {}
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "app.pkl",
        .data = "bird = read(\"prop:bird\")\n",
    });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir = path_buf[0..dir_len];
    const app = try std.fs.path.join(std.testing.allocator, &.{ dir, "app.pkl" });
    defer std.testing.allocator.free(app);
    const uri = try evaluator.fileUri(std.testing.allocator, std.testing.io, app);
    defer std.testing.allocator.free(uri);

    const command = try pklCommand(std.testing.allocator);
    defer std.testing.allocator.free(command);
    var ev = try evaluator.Evaluator.openProject(std.testing.allocator, std.testing.io, std.testing.environ, dir, .{
        .command = command,
    });
    defer ev.deinit();
    var decoded = ev.evaluateExpression(.{ .uri = uri }, "bird") catch |err| {
        std.debug.print("pkl diagnostic:\n{s}\n", .{ev.diagnostic()});
        return err;
    };
    defer decoded.deinit();
    try std.testing.expectEqualStrings("canary", decoded.value.string);
}

test "generate emits zig structs for the schema" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.pkl", .data = config_pkl });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..dir_len], "config.pkl" });
    defer std.testing.allocator.free(path);

    const command = try pklCommand(std.testing.allocator);
    defer std.testing.allocator.free(command);
    var diag: std.ArrayList(u8) = .empty;
    defer diag.deinit(std.testing.allocator);
    var file = codegen.generate(std.testing.allocator, std.testing.io, std.testing.environ, path, .{
        .evaluator = .{ .command = command },
    }, &diag) catch |err| {
        std.debug.print("codegen diagnostic:\n{s}\n", .{diag.items});
        return err;
    };
    defer file.deinit();

    try std.testing.expectEqualStrings("config.pkl.zig", file.filename);
    try std.testing.expect(std.mem.indexOf(u8, file.contents, "DO NOT EDIT") != null);
    try std.testing.expect(std.mem.indexOf(u8, file.contents, "pub const Config = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, file.contents, "name: []u8,") != null);
    try std.testing.expect(std.mem.indexOf(u8, file.contents, "replicas: i64,") != null);
    try std.testing.expect(std.mem.indexOf(u8, file.contents, "enabled: bool,") != null);
    try std.testing.expect(std.mem.indexOf(u8, file.contents, "tags: [][]u8,") != null);
    try std.testing.expect(std.mem.indexOf(u8, file.contents, "labels: pkl.typed.Entries([]u8, []u8),") != null);
    try std.testing.expect(std.mem.indexOf(u8, file.contents, "ports: []i64,") != null);
    try std.testing.expect(std.mem.indexOf(u8, file.contents, "coords: pkl.typed.PairOf(i64, i64),") != null);
    try std.testing.expect(std.mem.indexOf(u8, file.contents, "timeout: pkl.Duration,") != null);
    try std.testing.expect(std.mem.indexOf(u8, file.contents, "maxSize: pkl.DataSize,") != null);
    try std.testing.expect(std.mem.indexOf(u8, file.contents, "nickname: ?[]u8,") != null);
    try std.testing.expect(std.mem.indexOf(u8, file.contents, "endpoints: []Endpoint,") != null);
    try std.testing.expect(std.mem.indexOf(u8, file.contents, "pub const Endpoint = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, file.contents, "pub const Method = enum { GET, POST };") != null);
    try std.testing.expect(std.mem.indexOf(u8, file.contents, "/// The service name.") != null);
    try std.testing.expect(std.mem.indexOf(u8, file.contents, "/// Application configuration.") != null);
}

test "int sequence includes both ends" {
    const seq = value.IntSeq{ .start = 3, .end = 3, .step = -1 };
    var it = seq.iterator();
    try std.testing.expectEqual(@as(?i64, 3), it.next());
    try std.testing.expectEqual(@as(?i64, null), it.next());
}
