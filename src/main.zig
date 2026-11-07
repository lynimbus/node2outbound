//! node2outbound —— 把 clash 配置中的节点转换为 sing-box outbounds。
//!
//! 用法：
//!   node2outbound -u <订阅链接> [-A <User-Agent>] [--header "Name: value"]... \
//!                 [-o <outbounds.json>] [-g [组名]]
//!   node2outbound [-i <clash.yaml>] [-o <outbounds.json>] [-g [组名]]
//!
//! 默认从 stdin 读取、向 stdout 输出；给出 -u 时直接拉取订阅，不读 stdin。
//!
//! 退出码契约：
//!   - 0：成功产出 outbounds（部分节点被跳过时仍为 0，跳过明细写 stderr）；
//!   - 1：硬失败——输入/订阅/解析错误，或没有任何节点可转换。

const std = @import("std");
const yaml = @import("yaml.zig");
const convert = @import("convert.zig");
const subscribe = @import("subscribe.zig");

// Zig 0.17 起 `zig test` 不再自动发现导入模块中的 test 块（只发现根文件里的），
// 显式引用各模块顶层声明，让 `zig build test` 真正跑起来（非测试构建下为 no-op）。
comptime {
    std.testing.refAllDecls(yaml);
    std.testing.refAllDecls(convert);
    std.testing.refAllDecls(subscribe);
}

const usage_text =
    \\node2outbound - 把 clash 配置中的节点转换为 sing-box outbounds
    \\
    \\用法:
    \\  node2outbound -u <订阅链接> [-A <User-Agent>] [--header "Name: value"]... [-o <文件>] [-g [组名]]
    \\  node2outbound [-i <clash.yaml>] [-o <outbounds.json>] [-g [组名]]
    \\
    \\选项:
    \\  -u, --url <订阅链接>       直接拉取 clash 订阅（默认 User-Agent: sing-box 1.14.0）
    \\  -A, --user-agent <UA>      拉取订阅时使用的 User-Agent（需配合 -u）
    \\      --header "Name: value" 附加请求头，可重复（需配合 -u）
    \\  -i, --input <文件>         输入 clash 配置文件（默认读 stdin，与 -u 互斥）
    \\  -o, --output <文件>        输出 sing-box JSON（默认写 stdout）
    \\  -g, --group [组名]         只输出 outbounds 的 tag 列表（JSON 数组），跳过与组名相同的 tag；
    \\                            默认组名 select，便于直接插入 selector 组的 outbounds
    \\  -h, --help                 显示帮助并退出
    \\
    \\示例:
    \\  node2outbound -u "https://example.com/sub" > outbounds.json
    \\  node2outbound -u "https://example.com/sub" -A "clash-verge/v2.2.0" > outbounds.json
    \\  node2outbound -i clash.yaml -o outbounds.json
    \\  cat clash.yaml | node2outbound > outbounds.json
    \\  node2outbound -i clash.yaml -g > select.txt
    \\
;

/// 命令行选项。`parseArgs` 的产物：纯数据，不含任何文件/网络句柄。
pub const Cli = struct {
    input_path: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    group_name: ?[]const u8 = null,
    url: ?[]const u8 = null,
    user_agent: []const u8 = subscribe.default_user_agent,
    headers: []const []const u8 = &.{},
    help: bool = false,
};

pub const CliError = error{
    MissingArgument,
    UnknownArgument,
    ConflictingInput,
    OptionsRequireUrl,
    BadHeader,
    OutOfMemory,
};

fn argIs(arg: []const u8, short: []const u8, long: []const u8) bool {
    return std.mem.eql(u8, arg, short) or std.mem.eql(u8, arg, long);
}

/// 纯函数：只做 argv 解析，不读写文件、不联网、不打印。
/// `args` 为 argv[1..]；`headers` 里保存命令行原始 `"Name: value"` 字符串（按出现顺序），
/// 由 `buildHeaders` 再拆成 HTTP 头。
pub fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) CliError!Cli {
    var cli: Cli = .{};
    var headers: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer headers.deinit(allocator);
    var saw_user_agent = false;
    var saw_header = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (argIs(arg, "-h", "--help")) {
            cli.help = true;
            break;
        } else if (argIs(arg, "-i", "--input")) {
            cli.input_path = try takeValue(args, &i);
            if (cli.url != null) return error.ConflictingInput;
        } else if (argIs(arg, "-o", "--output")) {
            cli.output_path = try takeValue(args, &i);
        } else if (argIs(arg, "-g", "--group")) {
            // 参数可选：紧跟的非 `-` 开头参数视为组名，否则默认 select
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                i += 1;
                cli.group_name = args[i];
            } else {
                cli.group_name = "select";
            }
        } else if (argIs(arg, "-u", "--url")) {
            cli.url = try takeValue(args, &i);
            if (cli.input_path != null) return error.ConflictingInput;
        } else if (argIs(arg, "-A", "--user-agent")) {
            cli.user_agent = try takeValue(args, &i);
            saw_user_agent = true;
        } else if (std.mem.eql(u8, arg, "--header")) {
            const raw = try takeValue(args, &i);
            if (std.mem.indexOfScalar(u8, raw, ':') == null) return error.BadHeader;
            try headers.append(allocator, raw);
            saw_header = true;
        } else {
            return error.UnknownArgument;
        }
    }

    if (!cli.help and (saw_user_agent or saw_header) and cli.url == null) return error.OptionsRequireUrl;

    cli.headers = try headers.toOwnedSlice(allocator);
    return cli;
}

/// 取 `args[*i]` 之后的一个参数作为选项值，并把 `*i` 前移。
fn takeValue(args: []const []const u8, i: *usize) CliError![]const u8 {
    if (i.* + 1 >= args.len) return error.MissingArgument;
    i.* += 1;
    return args[i.*];
}

/// 把 `--header "Name: value"` 拆成 HTTP 头：名字与值去首尾空白，值内部允许冒号。
fn buildHeaders(allocator: std.mem.Allocator, raw: []const []const u8) CliError![]const std.http.Header {
    if (raw.len == 0) return &.{};
    const out = try allocator.alloc(std.http.Header, raw.len);
    errdefer allocator.free(out);
    for (raw, 0..) |item, idx| {
        const colon = std.mem.indexOfScalar(u8, item, ':') orelse return error.BadHeader;
        out[idx] = .{
            .name = std.mem.trim(u8, item[0..colon], " \t"),
            .value = std.mem.trim(u8, item[colon + 1 ..], " \t"),
        };
    }
    return out;
}

/// 把 `CliError` 映射为 stderr 中文说明，并以退出码 1 结束。
fn failCli(io: std.Io, err: CliError) noreturn {
    switch (err) {
        error.MissingArgument => fail(io, "缺少选项的参数（-i/-o/-u/-A/--header 均需要值）", .{}),
        error.UnknownArgument => fail(io, "未知参数\n\n{s}", .{usage_text}),
        error.ConflictingInput => fail(io, "-u/--url 与 -i/--input 不能同时使用（订阅链接与本地文件二选一）", .{}),
        error.OptionsRequireUrl => fail(io, "-A/--user-agent 与 --header 需要配合 -u/--url 使用", .{}),
        error.BadHeader => fail(io, "--header 的值必须形如 \"Name: value\"（缺少冒号）", .{}),
        error.OutOfMemory => fail(io, "内存不足", .{}),
    }
}

/// 订阅响应分类：只有 `.content` 允许进入后续 YAML 解析。
const FetchOutcome = union(enum) {
    content: []const u8,
    challenge,
    not_modified,
    http_error: u16,
    empty,
};

/// 纯函数：把 `subscribe.Response` 归约为可判定的结果，
/// 验证页/304/非 200/空内容都不会被当作订阅正文。
fn classifyResponse(response: subscribe.Response) FetchOutcome {
    return switch (response.status) {
        .ok => if (response.content.len == 0) .empty else .{ .content = response.content },
        .challenge => .challenge,
        .not_modified => .not_modified,
        .http_error => .{ .http_error = response.http_status },
    };
}

/// 拉取订阅并把结果交给后续解析流程；任何非 `.ok` 状态都当作硬失败。
fn fetchSubscription(io: std.Io, allocator: std.mem.Allocator, cli: Cli) []const u8 {
    const url = cli.url.?;
    const extra_headers = buildHeaders(allocator, cli.headers) catch |err|
        failCli(io, err);

    const response = subscribe.fetch(allocator, io, .{
        .url = url,
        .user_agent = cli.user_agent,
        .extra_headers = extra_headers,
    }) catch |err| fail(io, "订阅拉取失败: {s}（{s}）", .{ @errorName(err), url });

    switch (classifyResponse(response)) {
        .content => |content| return content,
        .challenge => fail(io, "订阅返回了人机验证页（Cloudflare / 机场拦截页），不是订阅内容；" ++
            "可用 --user-agent（-A）指定浏览器 UA 后重试，当前 UA: {s}", .{cli.user_agent}),
        .not_modified => fail(io, "订阅请求返回 304 Not Modified，服务器没有返回内容", .{}),
        .http_error => |code| fail(io, "订阅请求失败: HTTP {d}（{s}）", .{ code, url }),
        .empty => fail(io, "订阅返回了空内容（{s}）", .{url}),
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 解析参数
    const argv = try init.minimal.args.toSlice(arena);
    const cli = parseArgs(arena, if (argv.len > 0) argv[1..] else argv) catch |err|
        failCli(io, err);

    if (cli.help) {
        try printStdout(io, usage_text);
        return;
    }

    // 读取输入：-u 走订阅拉取（arena 持有），否则读文件或 stdin（gpa 持有）。
    var owned_source: ?[]u8 = null;
    defer if (owned_source) |s| gpa.free(s);

    const source: []const u8 = if (cli.url != null)
        fetchSubscription(io, arena, cli)
    else if (cli.input_path) |p| blk: {
        const text = std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .unlimited) catch |err| switch (err) {
            error.FileNotFound => fail(io, "找不到输入文件: {s}", .{p}),
            else => fail(io, "读取 {s} 失败: {s}", .{ p, @errorName(err) }),
        };
        owned_source = text;
        break :blk text;
    } else blk: {
        var stdin_file = std.Io.File.stdin();
        var stdin_reader = stdin_file.reader(io, &.{});
        const text = stdin_reader.interface.allocRemaining(gpa, .unlimited) catch |err|
            fail(io, "读取 stdin 失败: {s}", .{@errorName(err)});
        owned_source = text;
        break :blk text;
    };

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
    const output: Output = if (cli.group_name) |gname| blk: {
        const tags = convert.collectTags(arena, outbounds, gname) catch |err|
            fail(io, "转换失败: {s}", .{@errorName(err)});
        break :blk .{ .tags = tags };
    } else .{ .outbounds = outbounds };

    if (cli.output_path) |p| {
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

test "parseArgs: -u 设置 url 且默认 UA 为 sing-box 1.14.0" {
    const cli = try parseArgs(std.testing.allocator, &.{ "-u", "https://example.com/sub" });
    defer std.testing.allocator.free(cli.headers);

    try std.testing.expectEqualStrings("https://example.com/sub", cli.url.?);
    try std.testing.expectEqualStrings("sing-box 1.14.0", cli.user_agent);
    try std.testing.expectEqualStrings(subscribe.default_user_agent, cli.user_agent);
    try std.testing.expect(cli.input_path == null);
    try std.testing.expect(cli.output_path == null);
    try std.testing.expect(cli.group_name == null);
    try std.testing.expectEqual(@as(usize, 0), cli.headers.len);
    try std.testing.expect(!cli.help);
}

test "parseArgs: -u 的长选项形式与 --url 等价" {
    const cli = try parseArgs(std.testing.allocator, &.{ "--url", "https://example.com/sub" });
    defer std.testing.allocator.free(cli.headers);

    try std.testing.expectEqualStrings("https://example.com/sub", cli.url.?);
    try std.testing.expectEqualStrings(subscribe.default_user_agent, cli.user_agent);
}

test "parseArgs: -A 覆盖默认 UA" {
    const cli = try parseArgs(std.testing.allocator, &.{
        "-u", "https://example.com/sub", "-A", "clash-verge/2.0",
    });
    defer std.testing.allocator.free(cli.headers);

    try std.testing.expectEqualStrings("clash-verge/2.0", cli.user_agent);
    try std.testing.expectEqualStrings("https://example.com/sub", cli.url.?);
}

test "parseArgs: --user-agent 长选项覆盖默认 UA" {
    const cli = try parseArgs(std.testing.allocator, &.{
        "--url", "https://example.com/sub", "--user-agent", "clash-verge/2.0",
    });
    defer std.testing.allocator.free(cli.headers);

    try std.testing.expectEqualStrings("clash-verge/2.0", cli.user_agent);
}

test "parseArgs: --header 原样保存含冒号的值" {
    const cli = try parseArgs(std.testing.allocator, &.{
        "-u", "https://example.com/sub", "--header", "X-Token: abc:def",
    });
    defer std.testing.allocator.free(cli.headers);

    try std.testing.expectEqual(@as(usize, 1), cli.headers.len);
    try std.testing.expectEqualStrings("X-Token: abc:def", cli.headers[0]);
}

test "parseArgs: 多个 --header 保持命令行顺序" {
    const cli = try parseArgs(std.testing.allocator, &.{
        "-u",  "https://example.com/sub",
        "--header", "X-Token: abc",
        "--header", "Referer: https://example.com/a:b",
    });
    defer std.testing.allocator.free(cli.headers);

    try std.testing.expectEqual(@as(usize, 2), cli.headers.len);
    try std.testing.expectEqualStrings("X-Token: abc", cli.headers[0]);
    try std.testing.expectEqualStrings("Referer: https://example.com/a:b", cli.headers[1]);
}

test "parseArgs: --header 缺冒号返回 BadHeader" {
    try std.testing.expectError(CliError.BadHeader, parseArgs(std.testing.allocator, &.{
        "-u", "https://example.com/sub", "--header", "bad",
    }));
}

test "parseArgs: -A 与 -u 同时出现不报错" {
    const cli = try parseArgs(std.testing.allocator, &.{
        "-A", "x", "-u", "https://example.com/sub",
    });
    defer std.testing.allocator.free(cli.headers);

    try std.testing.expectEqualStrings("x", cli.user_agent);
    try std.testing.expectEqualStrings("https://example.com/sub", cli.url.?);
}

test "parseArgs: -i 与 -u 同时出现返回 ConflictingInput" {
    try std.testing.expectError(CliError.ConflictingInput, parseArgs(std.testing.allocator, &.{
        "-i", "a.yaml", "-u", "https://example.com/sub",
    }));
    try std.testing.expectError(CliError.ConflictingInput, parseArgs(std.testing.allocator, &.{
        "-u", "https://example.com/sub", "-i", "a.yaml",
    }));
}

test "parseArgs: -A 无 -u 返回 OptionsRequireUrl" {
    try std.testing.expectError(CliError.OptionsRequireUrl, parseArgs(std.testing.allocator, &.{ "-A", "x" }));
}

test "parseArgs: --header 无 -u 返回 OptionsRequireUrl" {
    try std.testing.expectError(CliError.OptionsRequireUrl, parseArgs(std.testing.allocator, &.{
        "--header", "X-Token: abc",
    }));
}

test "parseArgs: -i 单独出现时仍指向输入文件" {
    const cli = try parseArgs(std.testing.allocator, &.{ "-i", "a.yaml" });
    defer std.testing.allocator.free(cli.headers);

    try std.testing.expectEqualStrings("a.yaml", cli.input_path.?);
    try std.testing.expect(cli.url == null);
}

test "parseArgs: 未知参数返回 UnknownArgument" {
    try std.testing.expectError(CliError.UnknownArgument, parseArgs(std.testing.allocator, &.{"--no-such-flag"}));
    try std.testing.expectError(CliError.UnknownArgument, parseArgs(std.testing.allocator, &.{"x.yaml"}));
}

test "parseArgs: -g 无值默认 select，有值取该值" {
    const dflt = try parseArgs(std.testing.allocator, &.{"-g"});
    defer std.testing.allocator.free(dflt.headers);
    try std.testing.expectEqualStrings("select", dflt.group_name.?);
    try std.testing.expect(dflt.url == null);
    try std.testing.expect(dflt.input_path == null);

    const named = try parseArgs(std.testing.allocator, &.{ "-g", "auto" });
    defer std.testing.allocator.free(named.headers);
    try std.testing.expectEqualStrings("auto", named.group_name.?);
}

test "parseArgs: -u 与 -g 组合时二者都生效" {
    const cli = try parseArgs(std.testing.allocator, &.{
        "-u", "https://example.com/sub", "-g", "auto", "-o", "out.json",
    });
    defer std.testing.allocator.free(cli.headers);

    try std.testing.expectEqualStrings("https://example.com/sub", cli.url.?);
    try std.testing.expectEqualStrings("auto", cli.group_name.?);
    try std.testing.expectEqualStrings("out.json", cli.output_path.?);
}

test "parseArgs: -h 与 --help 置 help" {
    const short = try parseArgs(std.testing.allocator, &.{"-h"});
    defer std.testing.allocator.free(short.headers);
    try std.testing.expect(short.help);
    try std.testing.expect(short.url == null);
    try std.testing.expectEqualStrings(subscribe.default_user_agent, short.user_agent);

    const long = try parseArgs(std.testing.allocator, &.{"--help"});
    defer std.testing.allocator.free(long.headers);
    try std.testing.expect(long.help);
}

test "parseArgs: 选项缺值返回 MissingArgument" {
    try std.testing.expectError(CliError.MissingArgument, parseArgs(std.testing.allocator, &.{"-i"}));
    try std.testing.expectError(CliError.MissingArgument, parseArgs(std.testing.allocator, &.{"-o"}));
    try std.testing.expectError(CliError.MissingArgument, parseArgs(std.testing.allocator, &.{"-u"}));
    try std.testing.expectError(CliError.MissingArgument, parseArgs(std.testing.allocator, &.{"-A"}));
    try std.testing.expectError(CliError.MissingArgument, parseArgs(std.testing.allocator, &.{"--header"}));
}

test "buildHeaders: 名字与值去首尾空白，值内部冒号保留" {
    const headers = try buildHeaders(std.testing.allocator, &.{"  X-Token :  abc:def  "});
    defer std.testing.allocator.free(headers);

    try std.testing.expectEqual(@as(usize, 1), headers.len);
    try std.testing.expectEqualStrings("X-Token", headers[0].name);
    try std.testing.expectEqualStrings("abc:def", headers[0].value);
}

test "buildHeaders: 无附加头时返回空切片" {
    const headers = try buildHeaders(std.testing.allocator, &.{});
    try std.testing.expectEqual(@as(usize, 0), headers.len);
}

test "classifyResponse: 人机验证页不会被当作订阅正文" {
    const page = "<!DOCTYPE html><html><title>Just a moment...</title></html>";
    const outcome = classifyResponse(.{
        .status = .challenge,
        .content = page,
        .http_status = 200,
        .userinfo = null,
    });
    try std.testing.expect(outcome == .challenge);
}

test "classifyResponse: 非 200 携带十进制状态码" {
    const outcome = classifyResponse(.{
        .status = .http_error,
        .content = "",
        .http_status = 403,
        .userinfo = null,
    });
    try std.testing.expectEqual(FetchOutcome.http_error, std.meta.activeTag(outcome));
    try std.testing.expectEqual(@as(u16, 403), outcome.http_error);
}

test "classifyResponse: 304 单独归类" {
    const outcome = classifyResponse(.{
        .status = .not_modified,
        .content = "",
        .http_status = 304,
        .userinfo = null,
    });
    try std.testing.expect(outcome == .not_modified);
}

test "classifyResponse: ok 透传正文" {
    const body = "proxies:\n  - name: a\n";
    const outcome = classifyResponse(.{
        .status = .ok,
        .content = body,
        .http_status = 200,
        .userinfo = "upload=1;",
    });
    try std.testing.expectEqualStrings(body, outcome.content);
}

test "classifyResponse: ok 但空内容不算成功" {
    const outcome = classifyResponse(.{
        .status = .ok,
        .content = "",
        .http_status = 200,
        .userinfo = null,
    });
    try std.testing.expect(outcome == .empty);
}

test "parseArgs: -h 之后的参数不再报错" {
    const cli = try parseArgs(std.testing.allocator, &.{ "-h", "--no-such-flag" });
    defer std.testing.allocator.free(cli.headers);

    try std.testing.expect(cli.help);
    try std.testing.expect(cli.url == null);
}

const blocked_ua = "curl" ++ "/8.0";

const ua_example_line = "node2outbound -u \"https://example.com/sub\" -A \"clash-verge/v2.2.0\" > outbounds.json";

test "usage_text: -A 示例使用 clash-verge/v2.2.0 且不再出现被挡掉的 UA" {
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "clash-verge/v2.2.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, blocked_ua) == null);
    try std.testing.expect(std.mem.indexOf(u8, usage_text, ua_example_line) != null);
}
