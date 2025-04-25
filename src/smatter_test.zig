const std = @import("std");
const smat = @import("smatter.zig");

const expect = std.testing.expect;

test "Smatter" {
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
        \\{ }{ }
        , .expected = 
        \\{"f":"test.json","i":0,"p":"$","o":"{}"}
        \\{"f":"test.json","i":1,"p":"$","o":"{}"}
        \\
        },
        .{ .source = 
        \\{ "a":1, "c": [], "b": {"d": 2}}
        , .expected = 
        \\{"f":"test.json","i":0,"p":"$.a","n":1}
        \\{"f":"test.json","i":0,"p":"$.c","o":"[]"}
        \\{"f":"test.json","i":0,"p":"$.b.d","n":2}
        \\
        },
        .{ .source = 
        \\{"a":1, "c": [ ], "b": {"d": 2}}
        \\[1, 2, 3]
        \\true
        \\false
        \\[ true, false, null, -1.23, 999999999999999999999999, "hello", "world" ]
        , .expected = 
        \\{"f":"test.json","i":0,"p":"$.a","n":1}
        \\{"f":"test.json","i":0,"p":"$.c","o":"[]"}
        \\{"f":"test.json","i":0,"p":"$.b.d","n":2}
        \\{"f":"test.json","i":1,"p":"$[0]","n":1}
        \\{"f":"test.json","i":1,"p":"$[1]","n":2}
        \\{"f":"test.json","i":1,"p":"$[2]","n":3}
        \\{"f":"test.json","i":2,"p":"$","b":true}
        \\{"f":"test.json","i":3,"p":"$","b":false}
        \\{"f":"test.json","i":4,"p":"$[0]","b":true}
        \\{"f":"test.json","i":4,"p":"$[1]","b":false}
        \\{"f":"test.json","i":4,"p":"$[2]","o":"null"}
        \\{"f":"test.json","i":4,"p":"$[3]","n":-1.23}
        \\{"f":"test.json","i":4,"p":"$[4]","n":999999999999999999999999}
        \\{"f":"test.json","i":4,"p":"$[5]","s":"hello"}
        \\{"f":"test.json","i":4,"p":"$[6]","s":"world"}
        \\
        },
        .{ .source = 
        \\null
        , .expected = 
        \\{"f":"test.json","i":0,"p":"$","o":"null"}
        \\
        },
        .{ .source = 
        \\null null
        , .expected = 
        \\{"f":"test.json","i":0,"p":"$","o":"null"}
        \\{"f":"test.json","i":1,"p":"$","o":"null"}
        \\
        },
        .{ .source = 
        \\{"\"": 1}
        \\{"": 2}
        \\{"\\": 3}
        \\{"\n": 4}
        , .expected = 
        \\{"f":"test.json","i":0,"p":"$[\"\\\"\"]","n":1}
        \\{"f":"test.json","i":1,"p":"$[\"\"]","n":2}
        \\{"f":"test.json","i":2,"p":"$[\"\\\\\"]","n":3}
        \\{"f":"test.json","i":3,"p":"$[\"\\n\"]","n":4}
        \\
        },
    };

    for (cases) |case| {
        var input = StringReader.init(case.source);
        var output = std.ArrayList(u8).init(std.testing.allocator);
        defer output.deinit();
        var sm = try smat.Smatter.init(
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
