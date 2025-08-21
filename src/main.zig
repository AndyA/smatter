const std = @import("std");
const clap = @import("clap");
const smat = @import("smatter.zig");

fn smatStream(
    alloc: std.mem.Allocator,
    source: []const u8,
    reader: *std.io.Reader,
    writer: *std.io.Writer,
) !void {
    var sm = try smat.Smatter.init(alloc, source, reader, writer);
    defer sm.deinit(alloc);

    sm.run() catch |err| {
        const file = if (std.mem.eql(u8, source, "-")) "<stdin>" else source;
        const nc = if (std.ascii.isPrint(sm.nc)) sm.nc else '?';
        std.debug.print(
            \\Syntax error: {s} ('{c}') at {s} in {s} line {d}, column {d}
            \\
        , .{ @errorName(err), nc, sm.path.items, file, sm.line, sm.col });
        std.process.exit(1);
    };
}

fn smatFile(source: []const u8, name_override: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var src: std.fs.File = if (std.mem.eql(u8, source, "-"))
        std.fs.File.stdin()
    else
        try std.fs.cwd().openFile(source, .{});

    var r_buf: [128 * 1024]u8 = undefined;
    var w_buf: [128 * 1024]u8 = undefined;

    var r = src.reader(&r_buf);
    var w = std.fs.File.stdout().writer(&w_buf);

    try smatStream(arena.allocator(), name_override, &r.interface, &w.interface);

    try w.interface.flush();
}

fn smatter(files: []const []const u8, name_override: ?[]const u8) !void {
    for (files) |file| {
        smatFile(file, name_override orelse file) catch |err| {
            std.debug.print("{s}: {s}\n", .{ file, @errorName(err) });
            std.process.exit(1);
        };
    }
}

fn help(comptime params: anytype) !void {
    var w_buf: [1024]u8 = undefined;
    var w = std.fs.File.stdout().writer(&w_buf);

    try w.interface.writeAll(
        \\Usage:
        \\    smatter [OPTIONS] <file>...
        \\
        \\Options:
        \\
    );

    try clap.help(&w.interface, clap.Help, &params, .{ .max_width = 75 });

    try w.interface.writeAll("\n");
    try w.interface.flush();
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    const parsers = comptime .{
        .name = clap.parsers.string,
        .file = clap.parsers.string,
    };

    const params = comptime clap.parseParamsComptime(
        \\    <file>...                 Files to process.
        \\    -h, --help                Display this help and exit.
        \\    -f, --filename <name>     Filename to use instead of '-' in the output 
        \\                              when reading from stdin. 
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = alloc,
    }) catch |err| {
        try diag.reportToFile(.stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0)
        return help(params);

    return smatter(res.positionals[0], res.args.filename);
}

test {
    _ = @import("smatter_test.zig");
}
