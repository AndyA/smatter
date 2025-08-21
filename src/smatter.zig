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
    reader: *std.io.Reader,
    writer: *std.io.Writer,

    path: std.ArrayList(u8),
    value: std.ArrayList(u8),

    index: usize = 0,
    nc: u8 = '.',
    line: usize = 1,
    col: usize = 0,

    const Self = @This();

    pub fn init(
        alloc: std.mem.Allocator,
        source: []const u8,
        reader: *std.io.Reader,
        writer: *std.io.Writer,
    ) !Self {
        var path = try std.ArrayList(u8).initCapacity(alloc, 1000);
        errdefer path.deinit(alloc);
        try path.append(alloc, '$');

        var value = try std.ArrayList(u8).initCapacity(alloc, 1000);
        errdefer value.deinit(alloc);

        var self = Self{
            .alloc = alloc,
            .source = source,
            .reader = reader,
            .writer = writer,
            .path = path,
            .value = value,
        };

        try self.advance();

        return self;
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        self.path.deinit(alloc);
        self.value.deinit(alloc);
    }

    fn advance(self: *Self) !void {
        if (self.nc == 0) return SmatterError.EndOfInput;
        self.nc = self.reader.takeByte() catch |err| brk: {
            if (err != error.EndOfStream) return err;
            break :brk 0;
        };
        self.col += 1;
    }

    fn skipSpace(self: *Self) !void {
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
        try self.value.append(self.alloc, self.nc);
        try self.advance();
    }

    fn niceError(self: Self, err: SmatterError) SmatterError!void {
        return if (self.nc == 0)
            SmatterError.EndOfInput
        else
            err;
    }

    fn clearValue(self: *Self) void {
        self.value.items.len = 0;
    }

    fn emit(self: *Self, type_name: []const u8, value: []const u8) !void {
        try self.writer.print(
            \\{{"f":"{s}","i":{d},"p":"{s}","{s}":{s}}}
            \\
        , .{ self.source, self.index, self.path.items, type_name, value });
    }

    fn scanString(self: *Self) ![]const u8 {
        self.clearValue();
        try self.keep();

        while (self.nc != '"') {
            if (self.nc == '\\') try self.keep();
            try self.keep();
        }

        try self.keep();

        return self.value.items;
    }

    fn requireString(self: *Self) ![]const u8 {
        try self.skipSpace();
        if (self.nc != '"') try self.niceError(SmatterError.BadString);
        return try self.scanString();
    }

    fn scanWord(self: *Self) ![]const u8 {
        self.clearValue();
        while (std.ascii.isAlphabetic(self.nc)) try self.keep();
        return self.value.items;
    }

    fn requireWord(self: *Self, comptime need: []const u8) ![]const u8 {
        const word = try self.scanWord();
        if (!std.mem.eql(u8, word, need)) try self.niceError(SmatterError.BadToken);
        return word;
    }

    fn scanDigits(self: *Self) !void {
        if (!std.ascii.isDigit(self.nc)) try self.niceError(SmatterError.BadNumber);
        while (std.ascii.isDigit(self.nc)) try self.keep();
    }

    fn scanNumber(self: *Self) ![]const u8 {
        self.clearValue();
        if (self.nc == '-') try self.keep();
        try self.scanDigits();
        if (self.nc == '.') {
            try self.keep();
            try self.scanDigits();
        }
        if (self.nc == 'e' or self.nc == 'E') {
            try self.keep();
            if (self.nc == '+' or self.nc == '-') try self.keep();
            try self.scanDigits();
        }
        return self.value.items;
    }

    fn addIndexToPath(self: *Self, index: usize) !void {
        var buffer: [30]u8 = undefined;
        const len = std.fmt.printInt(&buffer, index, 10, .lower, .{});
        try self.path.append(self.alloc, '[');
        try self.path.appendSlice(self.alloc, buffer[0..len]);
        try self.path.append(self.alloc, ']');
    }

    fn addKeyToPath(self: *Self, key: []const u8) !void {
        const alloc = self.alloc;
        const word = key[1 .. key.len - 1];
        if (ctype.isBareword(word)) {
            try self.path.append(alloc, '.');
            try self.path.appendSlice(alloc, word);
        } else {
            try self.path.appendSlice(alloc, "[\\\"");
            for (word) |c| {
                if (c == '\\' or c == '\"') try self.path.append(alloc, '\\');
                try self.path.append(alloc, c);
            }
            try self.path.appendSlice(alloc, "\\\"]");
        }
    }

    fn scanArray(self: *Self) !void {
        try self.advance();
        try self.skipSpace();
        if (self.nc == ']') {
            try self.advance();
            return self.emit("o", "\"[]\"");
        }

        const old_len = self.path.items.len;

        var index: usize = 0;
        while (true) : (index += 1) {
            self.path.items.len = old_len;
            try self.addIndexToPath(index);
            try self.scanJson();
            try self.skipSpace();

            if (self.nc == ']') {
                try self.advance();
                break;
            }
            if (self.nc != ',') try self.niceError(SmatterError.MissingComma);
            try self.advance();
        }

        // Not deferred so the path is preserved if we bail
        self.path.items.len = old_len;
    }

    fn scanObject(self: *Self) !void {
        try self.advance();
        try self.skipSpace();

        if (self.nc == '}') {
            try self.advance();
            return self.emit("o", "\"{}\"");
        }

        const old_len = self.path.items.len;

        while (true) {
            self.path.items.len = old_len;
            const key = try self.requireString();
            try self.addKeyToPath(key);
            try self.skipSpace();
            if (self.nc != ':') try self.niceError(SmatterError.MissingColon);
            try self.advance();

            try self.scanJson();
            try self.skipSpace();

            if (self.nc == '}') {
                try self.advance();
                break;
            }
            if (self.nc != ',') try self.niceError(SmatterError.MissingComma);
            try self.advance();
        }

        // Not deferred so the path is preserved if we bail
        self.path.items.len = old_len;
    }

    fn scanJson(self: *Self) anyerror!void {
        try self.skipSpace();

        return switch (self.nc) {
            '[' => try self.scanArray(),
            '{' => try self.scanObject(),
            '"' => self.emit("s", try self.scanString()),
            't' => self.emit("b", try self.requireWord("true")),
            'f' => self.emit("b", try self.requireWord("false")),
            'n' => {
                _ = try self.requireWord("null");
                try self.emit("o", "\"null\"");
            },
            '0'...'9', '-' => self.emit("n", try self.scanNumber()),
            else => self.niceError(SmatterError.BadToken),
        };
    }

    pub fn run(self: *Self) !void {
        self.index = 0;
        while (true) : (self.index += 1) {
            try self.scanJson();
            try self.skipSpace();
            if (self.nc == ',') {
                try self.advance();
                try self.skipSpace();
            }
            if (self.nc == 0) break;
        }
    }
};

test {
    _ = @import("smatter_test.zig");
}
