const std = @import("std");
const Editor = @import("editor.zig").Editor;

pub fn main() !void {
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) @panic("memory leak detected");
    }

    var editor = try Editor.init(allocator, stdout);
    defer editor.deinit();
    defer editor.refreshScreen(false) catch {};

    const filename = try std.fs.cwd().realpathAlloc(allocator, "test.txt");
    defer allocator.free(filename);

    try editor.open(filename);

    while (true) {
        try editor.refreshScreen(true);
        const command = try editor.processInput(stdin);
        if (command == .exit) {
            return;
        }
    }
}
