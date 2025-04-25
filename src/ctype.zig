const std = @import("std");

test "isSymbolStart" {
    try std.testing.expect(isSymbolStart('a'));
    try std.testing.expect(isSymbolStart('A'));
    try std.testing.expect(isSymbolStart('_'));
    try std.testing.expect(!isSymbolStart('1'));
    try std.testing.expect(!isSymbolStart(' '));
}

pub fn isSymbolStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

test "isSymbol" {
    try std.testing.expect(isSymbol('a'));
    try std.testing.expect(isSymbol('A'));
    try std.testing.expect(isSymbol('_'));
    try std.testing.expect(isSymbol('1'));
    try std.testing.expect(!isSymbol(' '));
}

pub fn isSymbol(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

test "isBareword" {
    try std.testing.expect(isBareword("a"));
    try std.testing.expect(isBareword("A"));
    try std.testing.expect(isBareword("_"));
    try std.testing.expect(isBareword("a1"));
    try std.testing.expect(!isBareword("1"));
    try std.testing.expect(!isBareword(" "));
    try std.testing.expect(!isBareword(""));
}

pub fn isBareword(key: []const u8) bool {
    if (key.len == 0) return false;
    if (!isSymbolStart(key[0])) return false;
    for (key[1..]) |c| if (!isSymbol(c)) return false;
    return true;
}
