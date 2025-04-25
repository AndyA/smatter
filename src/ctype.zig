const std = @import("std");

pub fn is_symbol_start(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

test "is_symbol_start" {
    try std.testing.expect(is_symbol_start('a'));
    try std.testing.expect(is_symbol_start('A'));
    try std.testing.expect(is_symbol_start('_'));
    try std.testing.expect(!is_symbol_start('1'));
    try std.testing.expect(!is_symbol_start(' '));
}

pub fn is_symbol(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

test "is_symbol" {
    try std.testing.expect(is_symbol('a'));
    try std.testing.expect(is_symbol('A'));
    try std.testing.expect(is_symbol('_'));
    try std.testing.expect(is_symbol('1'));
    try std.testing.expect(!is_symbol(' '));
}

pub fn is_bareword(key: []const u8) bool {
    if (key.len == 0) return false;
    if (!is_symbol_start(key[0])) return false;
    for (key[1..]) |c| if (!is_symbol(c)) return false;
    return true;
}

test "is_bareword" {
    try std.testing.expect(is_bareword("a"));
    try std.testing.expect(is_bareword("A"));
    try std.testing.expect(is_bareword("_"));
    try std.testing.expect(is_bareword("a1"));
    try std.testing.expect(!is_bareword("1"));
    try std.testing.expect(!is_bareword(" "));
    try std.testing.expect(!is_bareword(""));
}
