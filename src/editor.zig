const std = @import("std");
const fs = std.fs;
const linux = std.os.linux;

const Allocator = std.mem.Allocator;

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

const TextRow = struct {
    line: []const u8,
};

pub const Editor = struct {
    cursor_x: u16 = 0,
    cursor_y: u16 = 0,
    screen_rows: u16,
    screen_cols: u16,
    original_termios: linux.termios,
    text_rows_count: u32 = 0,
    rows: std.ArrayList(TextRow),
    terminal: std.fs.File.Writer,
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator, terminal: std.fs.File.Writer) !Self {
        const window_size = try getWindowSize();

        var editor: Self = .{
            .original_termios = undefined,
            .screen_rows = window_size[0],
            .screen_cols = window_size[1],
            .rows = std.ArrayList(TextRow).init(allocator),
            .terminal = terminal,
            .allocator = allocator,
        };

        try editor.enableRawMode();
        return editor;
    }

    pub fn deinit(self: Self) void {
        try self.disableRawMode();

        if (self.text_rows_count > 0) {
            for (self.rows.items) |row| {
                self.allocator.free(row.line);
            }
            self.rows.deinit();
        }
    }

    pub fn open(self: *Self, filename: []const u8) !void {
        const file = try std.fs.openFileAbsolute(filename, .{});
        defer file.close();
        const reader = file.reader();

        var lineIndex: u32 = 1;
        while (try reader.readUntilDelimiterOrEofAlloc(self.allocator, '\n', 8192)) |line| {
            self.text_rows_count = lineIndex;
            try self.rows.append(TextRow{ .line = line });
            lineIndex += 1;
        }
    }

    pub fn refreshScreen(self: *Self, with_rows: bool) !void {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        const writer = buffer.writer();

        // hide cursor
        _ = try writer.write("\x1b[?25l");
        // set cursor to top left
        _ = try writer.write("\x1b[H");

        if (with_rows) {
            try self.drawRows(writer, self.screen_rows);
            _ = try writer.write("\x1b[H");
        }

        // reposition cursor to coordinates
        _ = try writer.print("\x1b[{d};{d}H", .{ self.cursor_y + 1, self.cursor_x + 1 });

        // show cursor
        _ = try writer.write("\x1b[?25h");

        _ = try self.terminal.writeAll(buffer.items);
    }

    pub fn processInput(self: *Self, reader: std.fs.File.Reader) !Command {
        const pressedKey = try readKey(reader);

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
                        var times = self.screen_rows;
                        while (times > 0) : (times -= 1) {
                            self.moveCursor(if (movement_type == .page_down) .arrow_down else .arrow_up);
                        }
                    },
                    else => self.moveCursor(pressedKey.movement),
                }
                return .noop;
            },
        };
    }

    pub fn moveCursor(self: *Self, direction: Movement) void {
        switch (direction) {
            .arrow_left => {
                if (self.cursor_x != 0) {
                    self.cursor_x -= 1;
                }
            },
            .arrow_right => {
                if (self.cursor_x != self.screen_cols - 1) {
                    self.cursor_x += 1;
                }
            },
            .arrow_up => {
                if (self.cursor_y != 0) {
                    self.cursor_y -= 1;
                }
            },
            .arrow_down => {
                if (self.cursor_y != self.screen_rows - 1) {
                    self.cursor_y += 1;
                }
            },
            .home => self.cursor_x = 0,
            .end => self.cursor_x = self.screen_cols - 1,
            .delete => {},
            .page_down, .page_up => unreachable,
        }
    }

    fn drawRows(self: Self, writer: anytype, rows: u16) !void {
        for (0..rows) |row| {
            if (row >= self.text_rows_count) {
                if (self.text_rows_count == 0 and row == self.screen_rows / 3) {
                    // add welcome message and padding
                    const welcome_msg = std.fmt.comptimePrint("Kilo Editor -- version {s}", .{version});
                    var padding = (self.screen_cols - welcome_msg.len) / 2;
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
            } else {
                _ = try writer.write(self.rows.items[row].line);
            }

            // clear line
            _ = try writer.write("\x1b[K");

            if (row < self.screen_rows - 1) {
                _ = try writer.write("\r\n");
            }
        }
    }

    fn enableRawMode(self: *Self) !void {
        const stdoutHandle = std.io.getStdOut().handle;
        _ = linux.tcgetattr(stdoutHandle, &self.original_termios);

        var raw = self.original_termios;
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

    fn disableRawMode(self: Self) !void {
        _ = linux.tcsetattr(std.io.getStdOut().handle, .FLUSH, &self.original_termios);
    }
};

fn getWindowSize() ![2]u16 {
    var ws: linux.winsize = undefined;

    const errorCode = linux.ioctl(std.io.getStdOut().handle, linux.T.IOCGWINSZ, @intFromPtr(&ws));
    if (errorCode == -1)
        return error.SyscallError;
    return [_]u16{ ws.ws_row, ws.ws_col };
}

fn readKey(reader: std.fs.File.Reader) !KeyPress {
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

/// return code for key as if control was applied
inline fn keyWithControl(key: u8) u8 {
    // control_code is 00011111 bitmask
    return std.ascii.control_code.us & key;
}
