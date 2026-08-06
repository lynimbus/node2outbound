//! node2outbound —— 把 clash 配置中的节点转换为 sing-box outbounds。
//!
//! 用法：
//!   node2outbound [-i <clash.yaml>] [-o <outbounds.json>]
//!
//! 默认从 stdin 读取、向 stdout 输出。

const std = @import("std");
const yaml = @import("yaml.zig");
const convert = @import("convert.zig");

const usage_text =
    \\node2outbound - 把 clash 配置中的节点转换为 sing-box outbounds
    \\
    \\用法:
    \\  node2outbound [-i <clash.yaml>] [-o <outbounds.json>]
    \\
    \\选项:
    \\  -i, --input <文件>    输入 clash 配置文件（默认读 stdin）
    \\  -o, --output <文件>   输出 sing-box JSON（默认写 stdout）
    \\  -h, --help            显示帮助并退出
    \\
    \\示例:
    \\  node2outbound -i clash.yaml -o outbounds.json
    \\  cat clash.yaml | node2outbound > outbounds.json
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;

    // 解析参数
    const args = try init.minimal.args.toSlice(arena);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try printStdout(io, usage_text);
            return;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--input")) {
            i += 1;
            if (i >= args.len) fail(io, "缺少 {s} 的参数（clash 配置文件路径）", .{arg});
            input_path = args[i];
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) fail(io, "缺少 {s} 的参数（输出文件路径）", .{arg});
            output_path = args[i];
        } else {
            fail(io, "未知参数: {s}\n\n{s}", .{ arg, usage_text });
        }
    }

    // 读取输入
    const source = if (input_path) |p|
        std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .unlimited) catch |err| switch (err) {
            error.FileNotFound => fail(io, "找不到输入文件: {s}", .{p}),
            else => fail(io, "读取 {s} 失败: {s}", .{ p, @errorName(err) }),
        }
    else blk: {
        var stdin_file = std.Io.File.stdin();
        var stdin_reader = stdin_file.reader(io, &.{});
        break :blk stdin_reader.interface.allocRemaining(gpa, .unlimited) catch |err|
            fail(io, "读取 stdin 失败: {s}", .{@errorName(err)});
    };
    defer gpa.free(source);

    // 解析 + 转换
    const nodes = yaml.parseProxies(gpa, source) catch |err| switch (err) {
        error.MissingProxies => fail(io, "输入中没有找到 proxies 区块", .{}),
        else => fail(io, "解析失败: {s}", .{@errorName(err)}),
    };
    defer {
        for (nodes) |n| gpa.free(n.fields);
        gpa.free(nodes);
    }

    var skipped: usize = 0;
    const outbounds = convert.convert(gpa, nodes, &skipped) catch |err|
        fail(io, "转换失败: {s}", .{@errorName(err)});
    defer gpa.free(outbounds);

    if (skipped > 0) {
        var err_buf: [1024]u8 = undefined;
        var err_w = std.Io.File.Writer.init(.stderr(), io, &err_buf);
        try err_w.interface.print("node2outbound: 跳过 {d} 个不支持的节点类型\n", .{skipped});
        try err_w.interface.flush();
    }

    // 输出
    if (output_path) |p| {
        const f = std.Io.Dir.cwd().createFile(io, p, .{}) catch |err|
            fail(io, "写入 {s} 失败: {s}", .{ p, @errorName(err) });
        defer f.close(io);
        var buf: [8192]u8 = undefined;
        var w = std.Io.File.Writer.init(f, io, &buf);
        convert.writeOutbounds(&w.interface, outbounds) catch |err|
            fail(io, "写出失败: {s}", .{@errorName(err)});
        try w.interface.flush();
    } else {
        var buf: [8192]u8 = undefined;
        var w = std.Io.File.Writer.init(.stdout(), io, &buf);
        convert.writeOutbounds(&w.interface, outbounds) catch |err|
            fail(io, "写出失败: {s}", .{@errorName(err)});
        try w.interface.flush();
    }
}

/// 打印帮助文本到 stdout。
fn printStdout(io: std.Io, text: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.Writer.init(.stdout(), io, &buf);
    try w.interface.writeAll(text);
    try w.interface.flush();
}

/// 打印错误到 stderr 并以退出码 1 结束。
fn fail(io: std.Io, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [2048]u8 = undefined;
    var w = std.Io.File.Writer.init(.stderr(), io, &buf);
    w.interface.print("node2outbound: " ++ fmt ++ "\n", args) catch {};
    w.interface.flush() catch {};
    std.process.exit(1);
}
