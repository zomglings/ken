const std = @import("std");
const ken = @import("ken");
const Io = std.Io;

const usage =
    \\Usage: ken <command> [options]
    \\
    \\Commands:
    \\  init     Create a new ken database
    \\  add      Add a publication
    \\  note     Add or view notes
    \\  relate   Create a relationship between publications
    \\  list     List publications
    \\  search   Search publications
    \\  merge    Merge two ken databases
    \\  skill    Generate agent skills
    \\  pubkind  Manage publication kinds
    \\  relkind  Manage relationship kinds
    \\  help     Show this help message
    \\
;

const Command = enum {
    init,
    add,
    note,
    relate,
    list,
    search,
    merge,
    skill,
    pubkind,
    relkind,
    help,
};

pub fn main(process: std.process.Init) !void {
    const arena = process.arena.allocator();
    const args = try process.minimal.args.toSlice(arena);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), process.io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), process.io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    if (args.len < 2) {
        try stderr.print(usage, .{});
        try stderr.flush();
        return;
    }

    const cmd = std.meta.stringToEnum(Command, args[1]) orelse {
        try stderr.print("Unknown command: {s}\n\n" ++ usage, .{args[1]});
        try stderr.flush();
        return;
    };

    switch (cmd) {
        .help => {
            try stdout.print(usage, .{});
            try stdout.flush();
        },
        .pubkind => try handleKind(.pubkind, args, stdout, stderr),
        .relkind => try handleKind(.relkind, args, stdout, stderr),
        inline else => |tag| {
            try stderr.print("{s}: not yet implemented\n", .{@tagName(tag)});
            try stderr.flush();
        },
    }
}

fn handleKind(
    entity: ken.KindEntity,
    args: []const [:0]const u8,
    stdout: anytype,
    stderr: anytype,
) !void {
    const action = ken.parseKindArgs(args, 1) catch |err| {
        try ken.formatKindError(entity, err, stderr);
        try stderr.flush();
        return;
    };
    try ken.executeKindAction(entity, action, stdout);
    try stdout.flush();
}
