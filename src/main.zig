const std = @import("std");

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
    data: []const u8,
    writer: std.io.AnyWriter,

    pos: usize,
    index: usize,
    path: std.ArrayList(u8),

    const Self = @This();

    fn init(
        alloc: std.mem.Allocator,
        source: []const u8,
        data: []const u8,
        writer: std.io.AnyWriter,
    ) !Self {
        var path = try std.ArrayList(u8).initCapacity(alloc, 1000);
        try path.append('$');
        return Self{
            .alloc = alloc,
            .source = source,
            .data = data,
            .writer = writer,
            .pos = 0,
            .index = 0,
            .path = path,
        };
    }

    fn deinit(self: *Self) void {
        self.path.deinit();
    }

    fn eof(self: Self) bool {
        return self.pos >= self.data.len;
    }

    fn peek_next(self: *Self) u8 {
        while (!self.eof()) : (self.pos += 1) {
            const c = self.data[self.pos];
            if (!std.ascii.isWhitespace(c)) return c;
        }
        return 0;
    }

    fn skip_spaces(self: *Self) void {
        _ = self.peek_next();
    }

    fn get_next(self: *Self) u8 {
        if (self.eof()) return 0;
        const c = self.data[self.pos];
        self.pos += 1;
        return c;
    }

    fn scan_string(self: *Self) SmatterError![]const u8 {
        const start = self.pos;
        self.pos += 1;
        while (!self.eof()) : (self.pos += 1) {
            const c = self.data[self.pos];
            // End of string?
            if (c == '"') {
                self.pos += 1;
                return self.data[start..self.pos];
            }
            // Escaped character?
            if (c == '\\') self.pos += 1;
        }
        return SmatterError.BadString;
    }

    fn parse_string(self: *Self) SmatterError![]const u8 {
        if (self.peek_next() != '"') return SmatterError.BadString;
        return self.scan_string();
    }

    fn scan_word(self: *Self) []const u8 {
        const start = self.pos;
        while (!self.eof()) : (self.pos += 1) {
            const c = self.data[self.pos];
            if (!std.ascii.isAlphabetic(c)) break;
        }
        return self.data[start..self.pos];
    }

    fn scan_literal(self: *Self, comptime need: []const u8) SmatterError![]const u8 {
        const word = self.scan_word();
        if (!std.mem.eql(u8, word, need)) return SmatterError.BadToken;
        return word;
    }

    fn consume_digits(self: *Self, c: u8) SmatterError!u8 {
        if (!std.ascii.isDigit(c)) return SmatterError.BadNumber;
        while (true) {
            const cc = self.get_next();
            if (!std.ascii.isDigit(cc)) return cc;
        }
    }

    fn scan_number(self: *Self) SmatterError![]const u8 {
        const start = self.pos;
        if (self.peek_next() == '-') self.pos += 1;

        var c = try self.consume_digits(self.get_next());
        if (c == '.')
            c = try self.consume_digits(self.get_next());

        if (c == 'e' or c == 'E') {
            c = self.get_next();
            if (c == '+' or c == '-') c = self.get_next();
            c = try self.consume_digits(c);
        }

        if (c != 0) self.pos -= 1;
        return self.data[start..self.pos];
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
        self.pos += 1;
        if (self.peek_next() == ']') {
            self.pos += 1;
            return self.emit("o", "\"[]\"");
        }

        const old_len = self.path.items.len;
        defer self.path.items.len = old_len;

        var index: usize = 0;
        while (true) : (index += 1) {
            self.path.items.len = old_len;
            try self.add_index_to_path(index);
            try self.walk_json();

            self.skip_spaces();
            const c = self.get_next();

            if (c == ']') break;
            if (c != ',') return SmatterError.MissingComma;
        }
    }

    fn walk_object(self: *Self) !void {
        self.pos += 1;

        if (self.peek_next() == '}') {
            self.pos += 1;
            return self.emit("o", "\"{}\"");
        }

        const old_len = self.path.items.len;
        defer self.path.items.len = old_len;

        while (true) {
            self.path.items.len = old_len;
            const key = try self.parse_string();
            try self.add_key_to_path(key);

            self.skip_spaces();
            if (self.get_next() != ':') return SmatterError.MissingColon;

            try self.walk_json();

            self.skip_spaces();
            const c = self.get_next();

            if (c == '}') break;
            if (c != ',') return SmatterError.MissingComma;
        }
    }

    fn walk_json(self: *Self) anyerror!void {
        self.skip_spaces();

        if (self.eof())
            return SmatterError.EndOfInput;

        return switch (self.data[self.pos]) {
            '[' => self.walk_array(),
            '{' => self.walk_object(),
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
            if (self.peek_next() == ',') {
                self.pos += 1;
                self.skip_spaces();
            }
            if (self.eof()) break;
        }
    }
};

test "character fetching" {
    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();

    var sm = try Smatter.init(
        std.testing.allocator,
        "test.json",
        "\na",
        output.writer().any(),
    );
    defer sm.deinit();

    try expect(sm.eof() == false);
    try expect(sm.peek_next() == 'a');
    try expect(sm.eof() == false);
    try expect(sm.peek_next() == 'a');
    try expect(sm.get_next() == 'a');
    try expect(sm.eof() == true);
    try expect(sm.peek_next() == 0);
    try expect(sm.get_next() == 0);
}

test "scanning" {
    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();

    var sm = try Smatter.init(
        std.testing.allocator,
        "test.json",
        \\"","\"",hello,0,-1,1e-3,1.3,1.3E+3
    ,
        output.writer().any(),
    );
    defer sm.deinit();

    try expect(std.mem.eql(u8, try sm.scan_string(),
        \\""
    ));
    try expect(sm.get_next() == ',');
    try expect(std.mem.eql(u8, try sm.scan_string(),
        \\"\""
    ));
    try expect(sm.get_next() == ',');
    try expect(std.mem.eql(u8, sm.scan_word(), "hello"));
    try expect(sm.get_next() == ',');
    try expect(std.mem.eql(u8, try sm.scan_number(), "0"));
    try expect(sm.get_next() == ',');
    try expect(std.mem.eql(u8, try sm.scan_number(), "-1"));
    try expect(sm.get_next() == ',');
    try expect(std.mem.eql(u8, try sm.scan_number(), "1e-3"));
    try expect(sm.get_next() == ',');
    try expect(std.mem.eql(u8, try sm.scan_number(), "1.3"));
    try expect(sm.get_next() == ',');
    try expect(std.mem.eql(u8, try sm.scan_number(), "1.3E+3"));
}

test "json" {
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
        \\[1, 2, 3]
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
        var output = std.ArrayList(u8).init(std.testing.allocator);
        defer output.deinit();

        var sm = try Smatter.init(
            std.testing.allocator,
            "test.json",
            case.source,
            output.writer().any(),
        );
        defer sm.deinit();

        try sm.walk();
        try std.testing.expectEqualDeep(output.items, case.expected);
        // try expect(std.mem.eql(u8, output.items, case.expected));
    }
}

fn smatter(source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const file = try std.fs.cwd().openFile(source, .{});
    defer file.close();

    const md = try file.metadata();
    const data = try std.posix.mmap(
        null,
        md.size(),
        std.posix.PROT.READ,
        .{ .TYPE = .SHARED },
        file.handle,
        0,
    );
    defer std.posix.munmap(data);

    const out = std.io.getStdOut();
    var buf = std.io.bufferedWriter(out.writer());
    const writer = buf.writer().any();
    var sm = try Smatter.init(arena.allocator(), source, data, writer);
    defer sm.deinit();

    try sm.walk();
    try buf.flush();
}

pub fn main() !void {
    for (std.os.argv[1..]) |arg| {
        try smatter(std.mem.span(arg));
    }
}
