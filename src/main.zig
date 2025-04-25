const std = @import("std");
const cli = @import("zig-cli");
const smat = @import("smatter.zig");

const BW = std.io.BufferedWriter;
fn bufferedWriterSize(comptime size: usize, stream: anytype) BW(size, @TypeOf(stream)) {
    return .{ .unbuffered_writer = stream };
}

fn smat_stream(
    alloc: std.mem.Allocator,
    source: []const u8,
    reader: std.io.AnyReader,
    writer: std.io.AnyWriter,
) !void {
    var sm = try smat.Smatter.init(alloc, source, reader, writer);
    defer sm.deinit();

    sm.walk() catch |err| {
        const file = if (std.mem.eql(u8, source, "-")) "<stdin>" else source;
        const nc = if (std.ascii.isPrint(sm.nc)) sm.nc else '?';
        std.debug.print(
            \\Syntax error: {s} ('{c}') at {s} in {s} line {d}, column {d}
            \\
        , .{ @errorName(err), nc, sm.path.items, file, sm.line, sm.col });
        std.process.exit(1);
    };
}

fn smat_file(source: []const u8, name_override: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const out_stream = std.io.getStdOut();
    var out_buf = bufferedWriterSize(128 * 1024, out_stream.writer());
    const writer = out_buf.writer().any();

    if (std.mem.eql(u8, source, "-")) {
        const in_file = std.io.getStdIn();

        var in_buf = std.io.bufferedReaderSize(128 * 1024, in_file.reader());
        const reader = in_buf.reader().any();
        try smat_stream(arena.allocator(), name_override, reader, writer);
    } else {
        const in_file = try std.fs.cwd().openFile(source, .{});
        defer in_file.close();

        var in_buf = std.io.bufferedReaderSize(128 * 1024, in_file.reader());
        const reader = in_buf.reader().any();
        try smat_stream(arena.allocator(), source, reader, writer);
    }

    try out_buf.flush();
}

const Config = struct {
    files: []const []const u8,
    name_override: []const u8,
};

var config = Config{ .files = undefined, .name_override = "-" };

fn smatter() !void {
    for (config.files) |file| {
        smat_file(file, config.name_override) catch |err| {
            std.debug.print("{s}: {s}\n", .{ file, @errorName(err) });
            std.process.exit(1);
        };
    }
}

pub fn main() !void {
    var r = try cli.AppRunner.init(std.heap.page_allocator);

    const app = cli.App{
        .command = cli.Command{
            .name = "smatter",
            .options = try r.allocOptions(&.{
                .{
                    .long_name = "filename",
                    .short_alias = 'f',
                    .help = "Override the 'f' (filename) field in the output.",
                    .value_ref = r.mkRef(&config.name_override),
                },
            }),
            .target = cli.CommandTarget{
                .action = cli.CommandAction{
                    .positional_args = cli.PositionalArgs{
                        .required = try r.allocPositionalArgs(&.{
                            .{
                                .name = "files",
                                .help = "Files to process. Use '-' for stdin.",
                                .value_ref = r.mkRef(&config.files),
                            },
                        }),
                    },
                    .exec = smatter,
                },
            },
        },
    };

    return r.run(&app);
}
