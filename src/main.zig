const std = @import("std");
const fs = std.fs;
const linux = std.os.linux;

const version = "0.0.1";

const Command = enum {
    exit,
    noop,
};

const KeyType = enum {
    movement,
    symbol,
};

const KeyPress = union(KeyType) {
    movement: Movement,
    symbol: u8,
};

const Movement = enum {
    arrow_left,
    arrow_right,
    arrow_up,
    arrow_down,
    page_up,
    page_down,
    home,
    end,
    delete,
};

const EditorConfig = struct {
    cursor_x: u16 = 0,
    cursor_y: u16 = 0,
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

    defer editorRefreshScreen(stdout, false) catch unreachable;

    while (true) {
        try editorRefreshScreen(stdout, true);
        const command = try editorProcessKeypress(stdin);
        if (command == .exit) {
            return;
        }
    }
}

fn editorReadKey(reader: std.fs.File.Reader) !KeyPress {
    var buffer: [1]u8 = undefined;
    _ = try reader.read(&buffer);

    const symbol = buffer[0];
    const symbolKeypress = KeyPress{ .symbol = symbol };
    // if special escape sequence entered
    if (symbol == '\x1b') {
        var escapeBuffer: [3]u8 = undefined;
        const bytesRead = try reader.read(&escapeBuffer);
        if (bytesRead < 2) {
            return symbolKeypress;
        }

        if (escapeBuffer[0] == '[') {
            // map arrow keys to wasd for now for navigation
            return switch (escapeBuffer[1]) {
                'A' => return KeyPress{ .movement = .arrow_up },
                'B' => return KeyPress{ .movement = .arrow_down },
                'C' => return KeyPress{ .movement = .arrow_right },
                'D' => return KeyPress{ .movement = .arrow_left },
                'H' => return KeyPress{ .movement = .home },
                'F' => return KeyPress{ .movement = .end },
                '0'...'9' => {
                    if (escapeBuffer[2] != '~') return symbolKeypress;
                    var movement: Movement = undefined;
                    switch (escapeBuffer[1]) {
                        '3' => movement = .delete,
                        '1', '7' => movement = .home,
                        '4', '8' => movement = .end,
                        '5' => movement = .page_up,
                        '6' => movement = .page_down,
                        else => return symbolKeypress,
                    }
                    return KeyPress{ .movement = movement };
                },
                else => return symbolKeypress,
            };
        } else if (escapeBuffer[0] == 'O') {
            return switch (escapeBuffer[1]) {
                'H' => return KeyPress{ .movement = .home },
                'F' => return KeyPress{ .movement = .end },
                else => return symbolKeypress,
            };
        }
    }

    return symbolKeypress;
}

fn editorProcessKeypress(reader: std.fs.File.Reader) !Command {
    const pressedKey = try editorReadKey(reader);

    return switch (pressedKey) {
        .symbol => {
            return switch (pressedKey.symbol) {
                keyWithControl('q') => .exit,
                else => .noop,
            };
        },
        .movement => |movement_type| {
            switch (movement_type) {
                .page_up, .page_down => {
                    var times = config.screen_rows;
                    while (times > 0) : (times -= 1) {
                        editorMoveCursor(if (movement_type == .page_down) .arrow_down else .arrow_up);
                    }
                },
                else => editorMoveCursor(pressedKey.movement),
            }
            return .noop;
        },
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

    // reposition cursor to coordinates
    _ = try stringBufferWriter.print("\x1b[{d};{d}H", .{ config.cursor_y + 1, config.cursor_x + 1 });

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

/// move cursor coordinates in the editor
fn editorMoveCursor(direction: Movement) void {
    switch (direction) {
        .arrow_left => {
            if (config.cursor_x != 0) {
                config.cursor_x -= 1;
            }
        },
        .arrow_right => {
            if (config.cursor_x != config.screen_cols - 1) {
                config.cursor_x += 1;
            }
        },
        .arrow_up => {
            if (config.cursor_y != 0) {
                config.cursor_y -= 1;
            }
        },
        .arrow_down => {
            if (config.cursor_y != config.screen_rows - 1) {
                config.cursor_y += 1;
            }
        },
        .home => config.cursor_x = 0,
        .end => config.cursor_x = config.screen_cols - 1,
        .delete => {},
        .page_down, .page_up => unreachable,
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
