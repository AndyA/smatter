const std = @import("std");

pub fn main() !void {
    const in = std.io.getStdIn();
    var ibuf = std.io.bufferedReader(in.reader());
    var r = ibuf.reader();

    const out = std.io.getStdOut();
    var obuf = std.io.bufferedWriter(out.writer());
    const w = obuf.writer().any();

    var buf: [16384]u8 = undefined;
    while (true) {
        const n = try r.read(buf[0..]);
        if (n == 0) break;
        _ = try w.write(buf[0..n]);
    }
    try obuf.flush();
}
