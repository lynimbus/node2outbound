//! node2outbound —— 把 clash 配置中的节点转换为 sing-box outbounds。
//!
//! 用法：
//!   node2outbound [-i <clash.yaml>] [-o <outbounds.json>] [-g [组名]]
//!
//! 默认从 stdin 读取、向 stdout 输出。
//!
//! 退出码契约：
//!   - 0：成功产出 outbounds（部分节点被跳过时仍为 0，跳过明细写 stderr）；
//!   - 1：硬失败——输入/解析错误，或没有任何节点可转换。

const std = @import("std");
const yaml = @import("yaml.zig");
const convert = @import("convert.zig");

// Zig 0.17 起 `zig test` 不再自动发现导入模块中的 test 块（只发现根文件里的），
// 显式引用各模块顶层声明，让 `zig build test` 真正跑起来（非测试构建下为 no-op）。
comptime {
    std.testing.refAllDecls(yaml);
    std.testing.refAllDecls(convert);
}

const usage_text =
    \\node2outbound - 把 clash 配置中的节点转换为 sing-box outbounds
    \\
    \\用法:
    \\  node2outbound [-i <clash.yaml>] [-o <outbounds.json>] [-g [组名]]
    \\
    \\选项:
    \\  -i, --input <文件>    输入 clash 配置文件（默认读 stdin）
    \\  -o, --output <文件>   输出 sing-box JSON（默认写 stdout）
    \\  -g, --group [组名]    只输出 outbounds 的 tag 列表（JSON 数组），跳过与组名相同的 tag；
    \\                       默认组名 select，便于直接插入 selector 组的 outbounds
    \\  -h, --help            显示帮助并退出
    \\
    \\示例:
    \\  node2outbound -i clash.yaml -o outbounds.json
    \\  cat clash.yaml | node2outbound > outbounds.json
    \\  cat clash.yaml | node2outbound -g > select.txt
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var group_name: ?[]const u8 = null;

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
        } else if (std.mem.eql(u8, arg, "-g") or std.mem.eql(u8, arg, "--group")) {
            // 参数可选：紧跟的非 `-` 开头参数视为组名，否则默认 select
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                i += 1;
                group_name = args[i];
            } else {
                group_name = "select";
            }
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

    // 解析 YAML
    const doc = yaml.parse(arena, source) catch |err| switch (err) {
        error.OutOfMemory => fail(io, "内存不足", .{}),
        else => fail(io, "解析失败: {s}", .{@errorName(err)}),
    };
    if (doc.problem) |p| fail(io, "解析失败: {s}", .{p});

    // 定位 proxies 区块
    const root_map = doc.root.asMap() orelse fail(io, "输入不是 YAML 映射（顶层应为键值对）", .{});
    const proxies = root_map.get("proxies") orelse fail(io, "输入中没有找到 proxies 区块", .{});
    const proxies_list = proxies.asList() orelse fail(io, "proxies 不是列表", .{});

    // 转换
    var skipped: std.ArrayListUnmanaged(convert.SkipInfo) = .empty;
    const outbounds = convert.convert(arena, proxies_list, &skipped) catch |err|
        fail(io, "转换失败: {s}", .{@errorName(err)});

    if (outbounds.len == 0) {
        fail(io, "没有可转换的节点（{d} 个节点全部被跳过）", .{skipped.items.len});
    }

    // 跳过明细（stderr）
    if (skipped.items.len > 0) {
        var err_buf: [4096]u8 = undefined;
        var err_w = std.Io.File.Writer.init(.stderr(), io, &err_buf);
        const w = &err_w.interface;
        w.print("node2outbound: 跳过 {d} 个节点:\n", .{skipped.items.len}) catch {};
        for (skipped.items) |s| {
            w.print("  - {s}: {s}\n", .{ s.name, s.reason }) catch {};
        }
        w.flush() catch {};
    }

    // 输出：根据是否指定 -g 决定写 outbounds 还是 tag 列表
    const output: Output = if (group_name) |gname| blk: {
        const tags = convert.collectTags(arena, outbounds, gname) catch |err|
            fail(io, "转换失败: {s}", .{@errorName(err)});
        break :blk .{ .tags = tags };
    } else .{ .outbounds = outbounds };

    if (output_path) |p| {
        const f = std.Io.Dir.cwd().createFile(io, p, .{}) catch |err|
            fail(io, "写入 {s} 失败: {s}", .{ p, @errorName(err) });
        defer f.close(io);
        var buf: [8192]u8 = undefined;
        var w = std.Io.File.Writer.init(f, io, &buf);
        writeOutput(&w.interface, output) catch |err|
            fail(io, "写出失败: {s}", .{@errorName(err)});
        try w.interface.flush();
    } else {
        var buf: [8192]u8 = undefined;
        var w = std.Io.File.Writer.init(.stdout(), io, &buf);
        writeOutput(&w.interface, output) catch |err|
            fail(io, "写出失败: {s}", .{@errorName(err)});
        try w.interface.flush();
    }
}

/// 输出内容：完整 outbounds，或 `-g` 模式下的 tag 列表。
const Output = union(enum) {
    outbounds: []const convert.Outbound,
    tags: []const []const u8,
};

/// 把 Output 序列化为缩进 JSON 写到 writer（末尾带换行）。
fn writeOutput(writer: *std.Io.Writer, output: Output) !void {
    switch (output) {
        .outbounds => |obs| try convert.writeOutbounds(writer, obs),
        .tags => |tags| try convert.writeTagList(writer, tags),
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
