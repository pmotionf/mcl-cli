//! This module defines the necessary types and functions to declare, queue,
//! and execute commands. Furthermore, it includes the implementations of a few
//! general purpose commands that facilitate easier use of the MCS CLI utility.

const std = @import("std");

pub var registry: std.StringArrayHashMap(Command) = undefined;
pub var stop: std.atomic.Atomic(bool) = std.atomic.Atomic(bool).init(false);
pub var variables: std.BufMap = undefined;

var command_queue: std.ArrayList(CommandString) = undefined;

const CommandString = struct {
    buffer: [1024]u8,
    len: usize,
};

pub const Command = struct {
    /// Name of a command, as shown to/parsed from user.
    name: []const u8,
    /// List of argument names. Each argument should be wrapped in a "()" for
    /// required arguments, or "[]" for optional arguments.
    parameters: []const Parameter = &[_]Command.Parameter{},
    /// Short description of command.
    short_description: []const u8,
    /// Long description of command.
    long_description: []const u8,
    execute: *const fn ([][]const u8) anyerror!void,

    pub const Parameter = struct {
        name: []const u8,
        optional: bool = false,
        quotable: bool = true,
        resolve: bool = true,
    };
};

pub fn init() !void {
    arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    allocator = arena.allocator();

    registry = std.StringArrayHashMap(Command).init(allocator);
    variables = std.BufMap.init(allocator);
    command_queue = std.ArrayList(CommandString).init(allocator);
    stop.store(false, .Monotonic);

    try registry.put("HELP", .{
        .name = "HELP",
        .parameters = &[_]Command.Parameter{
            .{ .name = "command", .optional = true, .resolve = false },
        },
        .short_description = "Display detailed information about a command.",
        .long_description =
        \\Print a detailed description of a command's purpose, use, and other
        \\such aspects of consideration. A valid command name must be provided.
        \\If no command is provided, a list of all commands will be shown.
        ,
        .execute = &help,
    });
    try registry.put("VERSION", .{
        .name = "VERSION",
        .short_description = "Display the version of the MCS CLI.",
        .long_description =
        \\Print the currently running version of the Motion Control Software
        \\command line utility in Semantic Version format.
        ,
        .execute = &version,
    });
    try registry.put("SET", .{
        .name = "SET",
        .parameters = &[_]Command.Parameter{
            .{ .name = "variable", .resolve = false },
            .{ .name = "value" },
        },
        .short_description = "Set a variable equal to a value.",
        .long_description =
        \\Create a variable name that resolves to the provided value in all
        \\future commands. Variable names are case sensitive.
        ,
        .execute = &set,
    });
    try registry.put("GET", .{
        .name = "GET",
        .parameters = &[_]Command.Parameter{
            .{ .name = "variable", .resolve = false },
        },
        .short_description = "Retrieve the value of a variable.",
        .long_description =
        \\Retrieve the resolved value of a previously created variable name.
        \\Variable names are case sensitive.
        ,
        .execute = &get,
    });
    try registry.put("VARIABLES", .{
        .name = "VARIABLES",
        .short_description = "Display all variables with their values.",
        .long_description =
        \\Print all currently set variable names along with their values.
        ,
        .execute = &printVariables,
    });
    try registry.put("FILE", .{
        .name = "FILE",
        .parameters = &[_]Command.Parameter{.{ .name = "path" }},
        .short_description = "Queue commands listed in the provided file.",
        .long_description =
        \\Add commands listed in the provided file to the front of the command
        \\queue. All queued commands will run first before the user is prompted
        \\to enter a new manual command. The queue of commands will be cleared
        \\if interrupted with the `Ctrl-C` hotkey. The file path provided for
        \\this command must be either an absolute file path or relative to the
        \\executable's directory. If the path contains spaces, it should be
        \\enclosed in double quotes (e.g. "my file path").
        ,
        .execute = &file,
    });
    try registry.put("EXIT", .{
        .name = "EXIT",
        .short_description = "Exit the MCS command line utility.",
        .long_description =
        \\Gracefully terminate the PMF Motion Control Software command line
        \\utility, cleaning up resources and closing connections.
        ,
        .execute = &exit,
    });
}

pub fn deinit() void {
    stop.store(true, .Monotonic);
    defer stop.store(false, .Monotonic);
    variables.deinit();
    command_queue.deinit();
    registry.deinit();
    arena.deinit();
}

pub fn queueEmpty() bool {
    return command_queue.items.len == 0;
}

pub fn queueClear() void {
    command_queue.clearRetainingCapacity();
}

/// Checks if the `stop` flag is set, and if so returns an error.
pub fn checkCommandInterrupt() !void {
    if (stop.load(.Monotonic)) {
        defer stop.store(false, .Monotonic);
        queueClear();
        return error.CommandStopped;
    }
}

pub fn enqueue(input: []const u8) !void {
    var buffer = CommandString{
        .buffer = undefined,
        .len = undefined,
    };
    @memcpy(buffer.buffer[0..input.len], input);
    buffer.len = input.len;
    try command_queue.insert(0, buffer);
}

pub fn execute() !void {
    const cb = command_queue.pop();
    std.log.info("Running command: {s}\n", .{cb.buffer[0..cb.len]});
    try parseAndRun(cb.buffer[0..cb.len]);
}

fn parseAndRun(input: []const u8) !void {
    var token_iterator = std.mem.tokenizeSequence(u8, input, " ");
    var command: *Command = undefined;
    var command_buf: [32]u8 = undefined;
    if (token_iterator.next()) |token| {
        if (registry.getPtr(std.ascii.upperString(
            &command_buf,
            token,
        ))) |c| {
            command = c;
        } else return error.InvalidCommand;
    } else return;

    var params: [][]const u8 = try allocator.alloc(
        []const u8,
        command.parameters.len,
    );
    defer allocator.free(params);

    for (command.parameters, 0..) |param, i| {
        const _token = token_iterator.peek();
        defer _ = token_iterator.next();
        if (_token == null) {
            if (param.optional) {
                params[i] = "";
                continue;
            } else return error.MissingParameter;
        }
        var token = _token.?;

        // Resolve variables.
        if (param.resolve) {
            if (variables.get(token)) |val| {
                token = val;
            }
        }

        if (param.quotable) {
            if (token[0] == '"') {
                const start_ind: usize = token_iterator.index + 1;
                var len: usize = 0;
                while (token_iterator.next()) |tok| {
                    try checkCommandInterrupt();
                    if (tok[tok.len - 1] == '"') {
                        // 2 subtracted from length to account for the two
                        // quotation marks.
                        len += tok.len - 2;
                        break;
                    }
                    // Because the token was consumed with `.next`, the index
                    // here will be the start index of the next token.
                    len = token_iterator.index - start_ind;
                }
                params[i] = input[start_ind .. start_ind + len];
            } else params[i] = token;
        } else {
            params[i] = token;
        }
    }
    if (token_iterator.peek() != null) return error.UnexpectedParameter;
    try command.execute(params);
}

var arena: std.heap.ArenaAllocator = undefined;
var allocator: std.mem.Allocator = undefined;

fn help(params: [][]const u8) !void {
    if (params[0].len > 0) {
        var command: *Command = undefined;
        var command_buf: [32]u8 = undefined;

        if (params[0].len > 32) return error.InvalidCommand;

        if (registry.getPtr(std.ascii.upperString(
            &command_buf,
            params[0],
        ))) |c| {
            command = c;
        } else return error.InvalidCommand;

        var params_buffer: [512]u8 = .{0} ** 512;
        var params_len: usize = 0;
        for (command.parameters) |param| {
            params_len += (try std.fmt.bufPrint(
                params_buffer[params_len..],
                " {s}{s}{s}",
                .{
                    if (param.optional) "[" else "(",
                    param.name,
                    if (param.optional) "]" else ")",
                },
            )).len;
        }
        std.log.info("\n\n{s}{s}:\n{s}{s}\n{s}\n{s}{s}\n\n", .{
            command.name,
            params_buffer[0..params_len],
            "====================================",
            "====================================",
            command.long_description,
            "====================================",
            "====================================",
        });
    } else {
        for (registry.values()) |c| {
            try checkCommandInterrupt();
            var params_buffer: [512]u8 = .{0} ** 512;
            var params_len: usize = 0;
            for (c.parameters) |param| {
                params_len += (try std.fmt.bufPrint(
                    params_buffer[params_len..],
                    " {s}{s}{s}",
                    .{
                        if (param.optional) "[" else "(",
                        param.name,
                        if (param.optional) "]" else ")",
                    },
                )).len;
            }
            std.log.info("{s}{s}:\n\t{s}\n", .{
                c.name,
                params_buffer[0..params_len],
                c.short_description,
            });
        }
    }
}

fn version(_: [][]const u8) !void {
    // TODO: Figure out better way to get version from `build.zig.zon`.
    std.log.info("CLI Version: {s}\n", .{"0.0.5"});
}

fn set(params: [][]const u8) !void {
    try variables.put(params[0], params[1]);
}

fn get(params: [][]const u8) !void {
    if (variables.get(params[0])) |value| {
        std.log.info("Variable \"{s}\": {s}\n", .{
            params[0],
            value,
        });
    } else return error.UndefinedVariable;
}

fn printVariables(_: [][]const u8) !void {
    var variables_it = variables.iterator();
    while (variables_it.next()) |entry| {
        try checkCommandInterrupt();
        std.log.info("\t{s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
}

fn file(params: [][]const u8) !void {
    var f = try std.fs.cwd().openFile(params[0], .{});
    var reader = f.reader();
    const current_len: usize = command_queue.items.len;
    var new_line: CommandString = .{ .buffer = undefined, .len = 0 };
    while (try reader.readUntilDelimiterOrEof(
        &new_line.buffer,
        '\n',
    )) |_line| {
        try checkCommandInterrupt();
        const line = std.mem.trimRight(u8, _line, "\r");
        new_line.len = line.len;
        std.log.info("Queueing command: {s}", .{line});
        try command_queue.insert(current_len, new_line);
    }
}

fn exit(_: [][]const u8) !void {
    std.os.exit(1);
}
