const std = @import("std");
const pkl = @import("pkl");

pub fn main(init: std.process.Init) u8 {
    run(init) catch |err| {
        std.debug.print("pkl-gen-zig: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();

    var out_dir: []const u8 = ".";
    var import_name: []const u8 = "pkl";
    var modules: std.ArrayList([]const u8) = .empty;
    defer modules.deinit(init.gpa);
    var help = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            help = true;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--out-dir")) {
            out_dir = args.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--import-name")) {
            import_name = args.next() orelse return error.MissingArgument;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("pkl-gen-zig: unknown option: {s}\n", .{arg});
            return error.UnknownOption;
        } else {
            try modules.append(init.gpa, arg);
        }
    }

    if (help or modules.items.len == 0) {
        var stdout_buf: [256]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(init.io, &stdout_buf);
        try stdout.interface.writeAll(usage);
        try stdout.interface.flush();
        if (!help) return error.MissingModule;
        return;
    }

    try std.Io.Dir.cwd().createDirPath(init.io, out_dir);
    for (modules.items) |module_path| {
        var diag: std.ArrayList(u8) = .empty;
        defer diag.deinit(init.gpa);
        var file = pkl.generate(init.gpa, init.io, init.minimal.environ, module_path, .{
            .import_name = import_name,
        }, &diag) catch |err| {
            if (diag.items.len > 0) std.debug.print("{s}\n", .{diag.items});
            return err;
        };
        defer file.deinit();
        const target = try std.fs.path.join(init.gpa, &.{ out_dir, file.filename });
        defer init.gpa.free(target);
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = target, .data = file.contents });
        std.debug.print("generated {s}\n", .{target});
    }
}

const usage =
    \\pkl-gen-zig — generate Zig types from Pkl modules
    \\
    \\Usage:
    \\  pkl-gen-zig [options] <module.pkl> [<module.pkl> ...]
    \\
    \\Options:
    \\  -o, --out-dir <dir>        Directory for generated .zig files (default: .)
    \\      --import-name <name>  @import name for the pkl module (default: pkl)
    \\  -h, --help                 Show this help
    \\
;
