const std = @import("std");
const fs = std.fs;
const linux = std.os.linux;

const version = "0.0.1";

const Command = enum {
    exit,
    noop,
};

const EditorConfig = struct {
    screen_rows: u16,
    screen_cols: u16,
    original_termios: linux.termios,
};
/// text editor global configuration instance
var config: EditorConfig = undefined;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

pub fn main() !void {
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    config = try editorInit();

    try enableRawMode();
    defer disableRawMode() catch unreachable;

    try editorRefreshScreen(stdout, true);
    defer editorRefreshScreen(stdout, false) catch unreachable;

    while (true) {
        const command = try editorProcessKeypress(stdin);
        if (command == .exit) {
            return;
        }
    }
}

fn editorReadKey(reader: std.fs.File.Reader) !u8 {
    var buffer: [1]u8 = undefined;
    const bytesRead = try reader.read(&buffer);
    _ = bytesRead;

    return buffer[0];
}

fn editorProcessKeypress(reader: std.fs.File.Reader) !Command {
    const symbol = try editorReadKey(reader);

    return switch (symbol) {
        keyWithControl('q') => .exit,
        else => .noop,
    };
}

fn editorRefreshScreen(writer: std.fs.File.Writer, with_rows: bool) !void {
    var stringBuffer = std.ArrayList(u8).init(allocator);
    defer stringBuffer.deinit();

    const stringBufferWriter = stringBuffer.writer();

    // hide cursor
    _ = try stringBufferWriter.write("\x1b[?25l");
    // set cursor to top left
    _ = try stringBufferWriter.write("\x1b[H");

    if (with_rows) {
        try editorDrawRows(config.screen_rows, stringBufferWriter);
        _ = try stringBufferWriter.write("\x1b[H");
    }

    // show cursor
    _ = try stringBufferWriter.write("\x1b[?25h");

    _ = try writer.writeAll(stringBuffer.items);
}

fn editorDrawRows(rows: u16, writer: anytype) !void {
    for (0..rows) |row| {
        // add welcome message and padding
        if (row == config.screen_rows / 3) {
            const welcome_msg = std.fmt.comptimePrint("Kilo Editor -- version {s}", .{version});
            var padding = (config.screen_cols - welcome_msg.len) / 2;
            if (padding > 0) {
                _ = try writer.write("~");
                padding -= 1;
            }

            while (padding > 0) : (padding -= 1) {
                _ = try writer.write(" ");
            }

            _ = try writer.write(welcome_msg);
        } else {
            _ = try writer.write("~");
        }

        // clear line
        _ = try writer.write("\x1b[K");

        if (row < config.screen_rows - 1) {
            _ = try writer.write("\r\n");
        }
    }
}

fn disableRawMode() !void {
    _ = linux.tcsetattr(std.io.getStdOut().handle, .FLUSH, &config.original_termios);
}

fn enableRawMode() !void {
    const stdoutHandle = std.io.getStdOut().handle;
    _ = linux.tcgetattr(stdoutHandle, &config.original_termios);

    var raw = config.original_termios;
    // disable echo
    raw.lflag.ECHO = false;
    // disable line inputs
    raw.lflag.ICANON = false;
    raw.lflag.IEXTEN = false;
    // disable sig events
    raw.lflag.ISIG = false;
    // disable control flow commands: ctrl+s ctrl+q
    raw.iflag.IXON = false;
    // disable carriage return
    raw.iflag.ICRNL = false;

    // disable newline cr output processing
    raw.oflag.OPOST = false;

    // other optional flags that are probably turned off already
    raw.iflag.BRKINT = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.cflag.CSIZE = .CS8;

    // disable input wait blocking
    raw.cc[@intFromEnum(linux.V.MIN)] = 0;
    raw.cc[@intFromEnum(linux.V.TIME)] = 1;

    _ = linux.tcsetattr(stdoutHandle, .FLUSH, &raw);
}

/// return code for key as if control was applied
inline fn keyWithControl(key: u8) u8 {
    // control_code is 00011111 bitmask
    return std.ascii.control_code.us & key;
}

fn getWindowSize() ![2]u16 {
    var ws: linux.winsize = undefined;

    const errorCode = linux.ioctl(std.io.getStdOut().handle, linux.T.IOCGWINSZ, @intFromPtr(&ws));
    if (errorCode == -1)
        return error.SyscallError;
    return [_]u16{ ws.ws_row, ws.ws_col };
}

fn editorInit() !EditorConfig {
    const window_size = try getWindowSize();

    return EditorConfig{
        .original_termios = undefined,
        .screen_rows = window_size[0],
        .screen_cols = window_size[1],
    };
}
