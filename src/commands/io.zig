const std = @import("std");

pub fn println(io: std.Io, parts: []const []const u8) !void {
    for (parts) |part| try std.Io.File.writeStreamingAll(.stdout(), io, part);
    try std.Io.File.writeStreamingAll(.stdout(), io, "\n");
}

pub fn eprintln(io: std.Io, parts: []const []const u8) !void {
    for (parts) |part| try std.Io.File.writeStreamingAll(.stderr(), io, part);
    try std.Io.File.writeStreamingAll(.stderr(), io, "\n");
}

pub fn readPromptLine(io: std.Io, buf: []u8) ![]const u8 {
    var len: usize = 0;
    while (true) {
        var byte: [1]u8 = undefined;
        const n = std.Io.File.readStreaming(.stdin(), io, &.{byte[0..]}) catch |err| switch (err) {
            error.EndOfStream => return std.mem.trim(u8, buf[0..len], " \t\r\n"),
            else => return err,
        };
        if (n == 0) return std.mem.trim(u8, buf[0..len], " \t\r\n");
        if (byte[0] == '\n') return std.mem.trim(u8, buf[0..len], " \t\r\n");
        if (len == buf.len) return error.InputTooLong;
        buf[len] = byte[0];
        len += 1;
    }
}
