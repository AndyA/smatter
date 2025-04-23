const std = @import("std");
const cli = @import("zig-cli");

const expect = std.testing.expect;

const SmatterError = error{
    BadToken,
    BadString,
    BadNumber,
    MissingComma,
    MissingColon,
    EndOfInput,
};

fn is_symbol_start(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn is_symbol(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn is_bareword(key: []const u8) bool {
    if (key.len == 0) return false;
    if (!is_symbol_start(key[0])) return false;
    for (key[1..]) |c| if (!is_symbol(c)) return false;
    return true;
}

const Smatter = struct {
    alloc: std.mem.Allocator,
    source: []const u8,
    reader: std.io.AnyReader,
    writer: std.io.AnyWriter,

    index: usize,
    path: std.ArrayList(u8),
    value: std.ArrayList(u8),
    nc: u8,
    line: usize,

    const Self = @This();

    fn init(
        alloc: std.mem.Allocator,
        source: []const u8,
        reader: std.io.AnyReader,
        writer: std.io.AnyWriter,
    ) !Self {
        var path = try std.ArrayList(u8).initCapacity(alloc, 1000);
        try path.append('$');
        const value = try std.ArrayList(u8).initCapacity(alloc, 1000);
        var self = Self{
            .alloc = alloc,
            .source = source,
            .reader = reader,
            .writer = writer,
            .index = 0,
            .path = path,
            .value = value,
            .nc = '.',
            .line = 1,
        };
        try self.advance();
        return self;
    }

    fn deinit(self: *Self) void {
        self.path.deinit();
        self.value.deinit();
    }

    fn advance(self: *Self) !void {
        if (self.nc == 0) return SmatterError.EndOfInput;
        if (self.reader.readByte()) |nc| {
            self.nc = nc;
        } else |err| {
            if (err != error.EndOfStream) return err;
            self.nc = 0;
        }
    }

    fn skip_space(self: *Self) !void {
        while (std.ascii.isWhitespace(self.nc)) {
            if (self.nc == '\n') self.line += 1;
            try self.advance();
        }
    }

    fn keep(self: *Self) !void {
        if (self.nc == 0) return SmatterError.EndOfInput;
        try self.value.append(self.nc);
        try self.advance();
    }

    fn clear_value(self: *Self) void {
        self.value.items.len = 0;
    }

    fn scan_string(self: *Self) ![]const u8 {
        self.clear_value();
        try self.keep();

        while (self.nc != '"') {
            if (self.nc == '\\') try self.keep();
            try self.keep();
        }

        try self.keep();

        return self.value.items;
    }

    fn parse_string(self: *Self) ![]const u8 {
        try self.skip_space();
        if (self.nc != '"') return SmatterError.BadString;
        return try self.scan_string();
    }

    fn scan_word(self: *Self) ![]const u8 {
        self.clear_value();
        while (std.ascii.isAlphabetic(self.nc)) try self.keep();
        return self.value.items;
    }

    fn scan_literal(self: *Self, comptime need: []const u8) ![]const u8 {
        const word = try self.scan_word();
        if (!std.mem.eql(u8, word, need)) return SmatterError.BadToken;
        return word;
    }

    fn consume_digits(self: *Self) !void {
        if (!std.ascii.isDigit(self.nc)) return SmatterError.BadNumber;
        while (std.ascii.isDigit(self.nc)) try self.keep();
    }

    fn scan_number(self: *Self) ![]const u8 {
        self.clear_value();
        if (self.nc == '-') try self.keep();
        try self.consume_digits();
        if (self.nc == '.') {
            try self.keep();
            try self.consume_digits();
        }
        if (self.nc == 'e' or self.nc == 'E') {
            try self.keep();
            if (self.nc == '+' or self.nc == '-') try self.keep();
            try self.consume_digits();
        }
        return self.value.items;
    }

    fn add_index_to_path(self: *Self, index: usize) !void {
        var buffer: [30]u8 = undefined;
        const len = std.fmt.formatIntBuf(&buffer, index, 10, .lower, .{});
        try self.path.append('[');
        try self.path.appendSlice(buffer[0..len]);
        try self.path.append(']');
    }

    fn add_key_to_path(self: *Self, key: []const u8) !void {
        const word = key[1 .. key.len - 1];
        if (is_bareword(word)) {
            try self.path.append('.');
            try self.path.appendSlice(word);
        } else {
            try self.path.appendSlice("[\\\"");
            for (word) |c| {
                if (c == '\\' or c == '\"') try self.path.append('\\');
                try self.path.append(c);
            }
            try self.path.appendSlice("\\\"]");
        }
    }

    fn walk_array(self: *Self) !void {
        if (self.nc != '[') return SmatterError.BadToken;
        try self.advance();
        try self.skip_space();
        if (self.nc == ']') {
            try self.advance();
            return self.emit("o", "\"[]\"");
        }

        const old_len = self.path.items.len;
        defer self.path.items.len = old_len;

        var index: usize = 0;
        while (true) : (index += 1) {
            self.path.items.len = old_len;
            try self.add_index_to_path(index);
            try self.walk_json();
            try self.skip_space();

            if (self.nc == ']') {
                try self.advance();
                break;
            }
            if (self.nc != ',') return SmatterError.MissingComma;
            try self.advance();
        }
    }

    fn walk_object(self: *Self) !void {
        if (self.nc != '{') return SmatterError.BadToken;
        try self.advance();
        try self.skip_space();

        if (self.nc == '}') {
            try self.advance();
            return self.emit("o", "\"{}\"");
        }

        const old_len = self.path.items.len;
        defer self.path.items.len = old_len;

        while (true) {
            self.path.items.len = old_len;
            const key = try self.parse_string();
            try self.add_key_to_path(key);
            try self.skip_space();
            if (self.nc != ':') return SmatterError.MissingColon;
            try self.advance();

            try self.walk_json();
            try self.skip_space();

            if (self.nc == '}') {
                try self.advance();
                break;
            }
            if (self.nc != ',') return SmatterError.MissingComma;
            try self.advance();
        }
    }

    fn walk_json(self: *Self) anyerror!void {
        try self.skip_space();

        if (self.nc == 0)
            return SmatterError.EndOfInput;

        return switch (self.nc) {
            '[' => try self.walk_array(),
            '{' => try self.walk_object(),
            '"' => self.emit("s", try self.scan_string()),
            't' => self.emit("b", try self.scan_literal("true")),
            'f' => self.emit("b", try self.scan_literal("false")),
            'n' => {
                _ = try self.scan_literal("null");
                try self.emit("o", "\"null\"");
            },
            '0'...'9', '-' => self.emit("n", try self.scan_number()),
            else => SmatterError.BadToken,
        };
    }

    fn emit(self: *Self, type_name: []const u8, value: []const u8) !void {
        try self.writer.print(
            \\{{"f":"{s}","i":{d},"p":"{s}","{s}":{s}}}
            \\
        , .{ self.source, self.index, self.path.items, type_name, value });
    }

    pub fn walk(self: *Self) !void {
        self.index = 0;
        while (true) : (self.index += 1) {
            try self.walk_json();
            try self.skip_space();
            if (self.nc == ',') {
                try self.advance();
                try self.skip_space();
            }
            if (self.nc == 0) break;
        }
    }
};

test "smatter" {
    const StringReader = struct {
        str: []const u8,
        pos: usize,

        const Error = error{NoError};
        const Self = @This();
        const Reader = std.io.Reader(*Self, Error, read);

        fn init(str: []const u8) Self {
            return Self{ .str = str, .pos = 0 };
        }

        fn read(self: *Self, dest: []u8) Error!usize {
            const avail = self.str.len - self.pos;
            const size = @min(avail, dest.len);
            @memcpy(dest[0..size], self.str[self.pos .. self.pos + size]);
            self.pos += size;
            return size;
        }

        fn reader(self: *Self) Reader {
            return .{ .context = self };
        }
    };

    const TestCase = struct {
        source: []const u8,
        expected: []const u8,
    };

    const cases = [_]TestCase{
        .{ .source = 
        \\[]
        , .expected = 
        \\{"f":"test.json","i":0,"p":"$","o":"[]"}
        \\
        },
        .{ .source = 
        \\[1]
        , .expected = 
        \\{"f":"test.json","i":0,"p":"$[0]","n":1}
        \\
        },
        .{ .source = 
        \\[ 1, 2, 3 ]
        , .expected = 
        \\{"f":"test.json","i":0,"p":"$[0]","n":1}
        \\{"f":"test.json","i":0,"p":"$[1]","n":2}
        \\{"f":"test.json","i":0,"p":"$[2]","n":3}
        \\
        },
        .{ .source = 
        \\{}
        , .expected = 
        \\{"f":"test.json","i":0,"p":"$","o":"{}"}
        \\
        },
        .{ .source = 
        \\{"a":1, "c": [], "b": {"d": 2}}
        , .expected = 
        \\{"f":"test.json","i":0,"p":"$.a","n":1}
        \\{"f":"test.json","i":0,"p":"$.c","o":"[]"}
        \\{"f":"test.json","i":0,"p":"$.b.d","n":2}
        \\
        },
        .{ .source = 
        \\{"a":1, "c": [], "b": {"d": 2}}
        \\[1, 2, 3]
        , .expected = 
        \\{"f":"test.json","i":0,"p":"$.a","n":1}
        \\{"f":"test.json","i":0,"p":"$.c","o":"[]"}
        \\{"f":"test.json","i":0,"p":"$.b.d","n":2}
        \\{"f":"test.json","i":1,"p":"$[0]","n":1}
        \\{"f":"test.json","i":1,"p":"$[1]","n":2}
        \\{"f":"test.json","i":1,"p":"$[2]","n":3}
        \\
        },
        .{ .source = 
        \\null
        , .expected = 
        \\{"f":"test.json","i":0,"p":"$","o":"null"}
        \\
        },
    };

    for (cases) |case| {
        var input = StringReader.init(case.source);
        var output = std.ArrayList(u8).init(std.testing.allocator);
        defer output.deinit();

        var sm = try Smatter.init(
            std.testing.allocator,
            "test.json",
            input.reader().any(),
            output.writer().any(),
        );
        defer sm.deinit();

        try sm.walk();
        try std.testing.expectEqualDeep(output.items, case.expected);
    }
}

const BW = std.io.BufferedWriter;
fn bufferedWriterSize(comptime size: usize, stream: anytype) BW(size, @TypeOf(stream)) {
    return .{ .unbuffered_writer = stream };
}

fn walk(
    alloc: std.mem.Allocator,
    source: []const u8,
    reader: std.io.AnyReader,
    writer: std.io.AnyWriter,
) !void {
    var sm = try Smatter.init(alloc, source, reader, writer);
    defer sm.deinit();
    try sm.walk();
}

fn smatter(source: []const u8, name_override: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const out_stream = std.io.getStdOut();
    var out_buf = bufferedWriterSize(128 * 1024, out_stream.writer());
    const writer = out_buf.writer().any();

    if (std.mem.eql(u8, source, "-")) {
        const in_file = std.io.getStdIn();
        var in_buf = std.io.bufferedReaderSize(128 * 1024, in_file.reader());
        const reader = in_buf.reader().any();
        try walk(arena.allocator(), name_override, reader, writer);
    } else {
        const in_file = try std.fs.cwd().openFile(source, .{});
        defer in_file.close();

        // const in_stream = std.io.getStdIn();
        var in_buf = std.io.bufferedReaderSize(128 * 1024, in_file.reader());
        const reader = in_buf.reader().any();
        try walk(arena.allocator(), source, reader, writer);
    }

    try out_buf.flush();
}

const Config = struct {
    files: []const []const u8,
    name_override: []const u8,
};

var config = Config{ .files = undefined, .name_override = "-" };

fn run_smatter() !void {
    for (config.files) |file| {
        try smatter(file, config.name_override);
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
                    .help = "Override the 'f' (filename) field in the output.",
                    .value_ref = r.mkRef(&config.name_override),
                },
            }),
            .target = cli.CommandTarget{
                .action = cli.CommandAction{
                    .positional_args = cli.PositionalArgs{
                        .optional = try r.allocPositionalArgs(&.{
                            .{
                                .name = "files",
                                .help = "Files to process. Use '-' for stdin.",
                                .value_ref = r.mkRef(&config.files),
                            },
                        }),
                    },
                    .exec = run_smatter,
                },
            },
        },
    };

    return r.run(&app);
}
