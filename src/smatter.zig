const std = @import("std");
const ctype = @import("ctype.zig");

pub const SmatterError = error{
    BadToken,
    BadString,
    BadNumber,
    MissingComma,
    MissingColon,
    EndOfInput,
};

pub const Smatter = struct {
    alloc: std.mem.Allocator,
    source: []const u8,
    reader: std.io.AnyReader,
    writer: std.io.AnyWriter,

    path: std.ArrayList(u8),
    value: std.ArrayList(u8),
    index: usize,

    nc: u8,
    line: usize,
    col: usize,

    const Self = @This();

    pub fn init(
        alloc: std.mem.Allocator,
        source: []const u8,
        reader: std.io.AnyReader,
        writer: std.io.AnyWriter,
    ) !Self {
        var path = try std.ArrayList(u8).initCapacity(alloc, 1000);
        errdefer path.deinit();
        try path.append('$');

        const value = try std.ArrayList(u8).initCapacity(alloc, 1000);
        errdefer value.deinit();

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
            .col = 0,
        };

        try self.advance();

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.path.deinit();
        self.value.deinit();
    }

    fn advance(self: *Self) !void {
        if (self.nc == 0) return SmatterError.EndOfInput;
        if (self.reader.readByte()) |nc| {
            self.nc = nc;
            self.col += 1;
        } else |err| {
            if (err != error.EndOfStream) return err;
            self.nc = 0;
        }
    }

    fn skip_space(self: *Self) !void {
        while (std.ascii.isWhitespace(self.nc)) {
            if (self.nc == '\n') {
                self.line += 1;
                self.col = 0;
            }
            try self.advance();
        }
    }

    fn keep(self: *Self) !void {
        if (self.nc == 0) return SmatterError.EndOfInput;
        try self.value.append(self.nc);
        try self.advance();
    }

    fn nice_error(self: Self, err: SmatterError) SmatterError!void {
        return if (self.nc == 0)
            SmatterError.EndOfInput
        else
            err;
    }

    fn clear_value(self: *Self) void {
        self.value.items.len = 0;
    }

    fn emit(self: *Self, type_name: []const u8, value: []const u8) !void {
        try self.writer.print(
            \\{{"f":"{s}","i":{d},"p":"{s}","{s}":{s}}}
            \\
        , .{ self.source, self.index, self.path.items, type_name, value });
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

    fn require_string(self: *Self) ![]const u8 {
        try self.skip_space();
        if (self.nc != '"') try self.nice_error(SmatterError.BadString);
        return try self.scan_string();
    }

    fn scan_word(self: *Self) ![]const u8 {
        self.clear_value();
        while (std.ascii.isAlphabetic(self.nc)) try self.keep();
        return self.value.items;
    }

    fn scan_literal(self: *Self, comptime need: []const u8) ![]const u8 {
        const word = try self.scan_word();
        if (!std.mem.eql(u8, word, need)) try self.nice_error(SmatterError.BadToken);
        return word;
    }

    fn consume_digits(self: *Self) !void {
        if (!std.ascii.isDigit(self.nc)) try self.nice_error(SmatterError.BadNumber);
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
        if (ctype.is_bareword(word)) {
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

    fn scan_array(self: *Self) !void {
        try self.advance();
        try self.skip_space();
        if (self.nc == ']') {
            try self.advance();
            return self.emit("o", "\"[]\"");
        }

        const old_len = self.path.items.len;

        var index: usize = 0;
        while (true) : (index += 1) {
            self.path.items.len = old_len;
            try self.add_index_to_path(index);
            try self.scan_json();
            try self.skip_space();

            if (self.nc == ']') {
                try self.advance();
                break;
            }
            if (self.nc != ',') try self.nice_error(SmatterError.MissingComma);
            try self.advance();
        }

        // Not deferred so the path is preserved if we bail
        self.path.items.len = old_len;
    }

    fn scan_object(self: *Self) !void {
        try self.advance();
        try self.skip_space();

        if (self.nc == '}') {
            try self.advance();
            return self.emit("o", "\"{}\"");
        }

        const old_len = self.path.items.len;

        while (true) {
            self.path.items.len = old_len;
            const key = try self.require_string();
            try self.add_key_to_path(key);
            try self.skip_space();
            if (self.nc != ':') try self.nice_error(SmatterError.MissingColon);
            try self.advance();

            try self.scan_json();
            try self.skip_space();

            if (self.nc == '}') {
                try self.advance();
                break;
            }
            if (self.nc != ',') try self.nice_error(SmatterError.MissingComma);
            try self.advance();
        }

        // Not deferred so the path is preserved if we bail
        self.path.items.len = old_len;
    }

    fn scan_json(self: *Self) anyerror!void {
        try self.skip_space();

        return switch (self.nc) {
            '[' => try self.scan_array(),
            '{' => try self.scan_object(),
            '"' => self.emit("s", try self.scan_string()),
            't' => self.emit("b", try self.scan_literal("true")),
            'f' => self.emit("b", try self.scan_literal("false")),
            'n' => {
                _ = try self.scan_literal("null");
                try self.emit("o", "\"null\"");
            },
            '0'...'9', '-' => self.emit("n", try self.scan_number()),
            else => self.nice_error(SmatterError.BadToken),
        };
    }

    pub fn walk(self: *Self) !void {
        self.index = 0;
        while (true) : (self.index += 1) {
            try self.scan_json();
            try self.skip_space();
            if (self.nc == ',') {
                try self.advance();
                try self.skip_space();
            }
            if (self.nc == 0) break;
        }
    }
};
