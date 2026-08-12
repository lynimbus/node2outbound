//! clash 配置的通用 YAML 解析，基于 vendored libyaml（MIT，见 vendor/libyaml/LICENSE）。
//!
//! 与旧的手写子集解析器不同，这里解析完整 YAML 1.1：
//! 嵌套 map（ws-opts / reality-opts / headers）、flow 语法（`- {name: x}`）、
//! 锚点/别名、任意缩进、单双引号、行内注释、CRLF。
//!
//! 结果是一棵 `Value` 树。所有字符串由调用方提供的 arena 分配，
//! 生命周期与 arena 一致（无逐节点释放）。
//!
//! 标量一律保留原始文本（数字、布尔也不例外），布尔语义由调用方按需解析，
//! 避免 YAML 1.1 把 `password: yes` 之类的值误判成布尔而丢失。

const std = @import("std");
const c = @import("c");

// translate-c 把 yaml_event_type_t 降级为 c_uint，枚举常量则是顶层 c_int。
// 这里统一为 c_uint 常量便于比较。
const STREAM_START_EVENT: c_uint = c.YAML_STREAM_START_EVENT;
const DOCUMENT_START_EVENT: c_uint = c.YAML_DOCUMENT_START_EVENT;
const DOCUMENT_END_EVENT: c_uint = c.YAML_DOCUMENT_END_EVENT;
const STREAM_END_EVENT: c_uint = c.YAML_STREAM_END_EVENT;
const SCALAR_EVENT: c_uint = c.YAML_SCALAR_EVENT;
const SEQUENCE_START_EVENT: c_uint = c.YAML_SEQUENCE_START_EVENT;
const SEQUENCE_END_EVENT: c_uint = c.YAML_SEQUENCE_END_EVENT;
const MAPPING_START_EVENT: c_uint = c.YAML_MAPPING_START_EVENT;
const MAPPING_END_EVENT: c_uint = c.YAML_MAPPING_END_EVENT;
const ALIAS_EVENT: c_uint = c.YAML_ALIAS_EVENT;

/// 一个 YAML 值。
pub const Value = union(enum) {
    empty,
    scalar: []const u8,
    list: []const Value,
    map: Map,

    pub fn asScalar(self: Value) ?[]const u8 {
        return switch (self) {
            .scalar => |s| s,
            else => null,
        };
    }

    pub fn asList(self: Value) ?[]const Value {
        return switch (self) {
            .list => |l| l,
            else => null,
        };
    }

    pub fn asMap(self: Value) ?Map {
        return switch (self) {
            .map => |m| m,
            else => null,
        };
    }
};

pub const Map = std.StringArrayHashMapUnmanaged(Value);

pub const Error = error{
    /// 事件流结构不符合预期（如根节点是容器结束事件）
    UnexpectedEvent,
    /// 引用了未定义的锚点
    InvalidAnchor,
    /// libyaml 解析失败（parse 会转成 Document.problem）
    ParseFailed,
    OutOfMemory,
};

/// 解析结果。`problem` 非空表示解析失败，此时 `root` 无意义。
pub const Document = struct {
    root: Value = .empty,
    problem: ?[]const u8 = null,
};

/// 解析一段 YAML 文本，返回第一个文档。
/// 解析失败不返回错误，而是返回带 `problem` 诊断信息的 Document。
pub fn parse(arena: std.mem.Allocator, source: []const u8) Error!Document {
    var parser: c.yaml_parser_t = undefined;
    if (c.yaml_parser_initialize(&parser) == 0) return error.OutOfMemory;
    defer c.yaml_parser_delete(&parser);

    c.yaml_parser_set_input_string(&parser, source.ptr, source.len);

    var anchors: std.StringHashMapUnmanaged(Value) = .empty;

    return parseBody(&parser, arena, &anchors) catch |err| switch (err) {
        error.ParseFailed => Document{
            .problem = problemText(&parser, arena),
        },
        else => return err,
    };
}

/// libyaml 解析失败时的事件循环主体；`error.ParseFailed` 由 `parse` 统一转换为诊断。
fn parseBody(parser: *c.yaml_parser_t, arena: std.mem.Allocator, anchors: *std.StringHashMapUnmanaged(Value)) Error!Document {
    var stream_start: c.yaml_event_t = undefined;
    try nextEvent(parser, &stream_start);
    defer c.yaml_event_delete(&stream_start);
    if (stream_start.type != STREAM_START_EVENT) return error.UnexpectedEvent;

    var doc_start: c.yaml_event_t = undefined;
    try nextEvent(parser, &doc_start);
    defer c.yaml_event_delete(&doc_start);
    if (doc_start.type != DOCUMENT_START_EVENT) return error.UnexpectedEvent;

    const root = switch (try parseNode(parser, arena, anchors)) {
        .value => |v| v,
        .end => return error.UnexpectedEvent,
    };

    var doc_end: c.yaml_event_t = undefined;
    try nextEvent(parser, &doc_end);
    defer c.yaml_event_delete(&doc_end);
    if (doc_end.type != DOCUMENT_END_EVENT) return error.UnexpectedEvent;

    var stream_end: c.yaml_event_t = undefined;
    try nextEvent(parser, &stream_end);
    defer c.yaml_event_delete(&stream_end);
    if (stream_end.type != STREAM_END_EVENT) return error.UnexpectedEvent;

    return .{ .root = root };
}

const NodeResult = union(enum) {
    value: Value,
    /// 容器（sequence/mapping）的结束事件
    end,
};

/// 读取下一个事件并构建节点。
fn parseNode(
    parser: *c.yaml_parser_t,
    arena: std.mem.Allocator,
    anchors: *std.StringHashMapUnmanaged(Value),
) Error!NodeResult {
    var ev: c.yaml_event_t = undefined;
    try nextEvent(parser, &ev);
    defer c.yaml_event_delete(&ev);

    return switch (ev.type) {
        SCALAR_EVENT => .{ .value = try scalarValue(arena, anchors, &ev.data.scalar) },
        SEQUENCE_START_EVENT => .{ .value = try parseSequence(parser, arena, anchors, anchorOf(&ev.data.sequence_start)) },
        MAPPING_START_EVENT => .{ .value = try parseMapping(parser, arena, anchors, anchorOf(&ev.data.mapping_start)) },
        ALIAS_EVENT => blk: {
            const name = std.mem.span(ev.data.alias.anchor);
            break :blk .{ .value = anchors.get(name) orelse return error.InvalidAnchor };
        },
        SEQUENCE_END_EVENT, MAPPING_END_EVENT => .end,
        else => error.UnexpectedEvent,
    };
}

fn scalarValue(
    arena: std.mem.Allocator,
    anchors: *std.StringHashMapUnmanaged(Value),
    sc: anytype,
) Error!Value {
    const text = try arena.dupe(u8, sc.value[0..sc.length]);
    if (sc.anchor) |a| {
        try anchors.put(arena, try arena.dupe(u8, std.mem.span(a)), .{ .scalar = text });
    }
    return .{ .scalar = text };
}

fn parseSequence(
    parser: *c.yaml_parser_t,
    arena: std.mem.Allocator,
    anchors: *std.StringHashMapUnmanaged(Value),
    anchor: ?[]const u8,
) Error!Value {
    var items: std.ArrayListUnmanaged(Value) = .empty;
    while (true) {
        switch (try parseNode(parser, arena, anchors)) {
            .end => break,
            .value => |v| try items.append(arena, v),
        }
    }
    const list = try items.toOwnedSlice(arena);
    if (anchor) |a| {
        try anchors.put(arena, try arena.dupe(u8, a), .{ .list = list });
    }
    return .{ .list = list };
}

fn parseMapping(
    parser: *c.yaml_parser_t,
    arena: std.mem.Allocator,
    anchors: *std.StringHashMapUnmanaged(Value),
    anchor: ?[]const u8,
) Error!Value {
    var map: Map = .empty;
    var pending_key: ?[]const u8 = null;
    while (true) {
        switch (try parseNode(parser, arena, anchors)) {
            .end => break,
            .value => |v| {
                if (pending_key) |k| {
                    try map.put(arena, k, v);
                    pending_key = null;
                } else {
                    pending_key = v.asScalar() orelse return error.UnexpectedEvent;
                }
            },
        }
    }
    if (pending_key != null) return error.UnexpectedEvent;
    if (anchor) |a| {
        try anchors.put(arena, try arena.dupe(u8, a), .{ .map = map });
    }
    return .{ .map = map };
}

/// 从 sequence/mapping 的 start 事件里取锚点（仅事件存活期间有效）。
fn anchorOf(start: anytype) ?[]const u8 {
    const a = start.anchor orelse return null;
    return std.mem.span(a);
}

fn nextEvent(parser: *c.yaml_parser_t, out: *c.yaml_event_t) Error!void {
    if (c.yaml_parser_parse(parser, out) == 0) return error.ParseFailed;
}

/// 提取 libyaml 的失败诊断文本（arena 所有）。
fn problemText(parser: *c.yaml_parser_t, arena: std.mem.Allocator) ?[]const u8 {
    const p = parser.problem orelse return null;
    return arena.dupe(u8, std.mem.span(p)) catch null;
}

// ---------- tests ----------

const testing = std.testing;

const ParseError = Error;

test "parse nested maps, flow syntax, comments, crlf" {
    const text =
        \\mixed-port: 7890
        \\proxies:
        \\  - name: "节点 A"   # 行内注释
        \\    type: ss
        \\    server: 1.2.3.4
        \\    port: 8388
        \\    cipher: aes-256-gcm
        \\    password: 'p@ss#word'
        \\    ws-opts:
        \\      path: /ws
        \\      headers:
        \\        Host: example.com
        \\  - { name: flow-node, type: vless, server: 2.2.2.2, port: 443, tls: true, network: ws }
        \\proxy-groups:
        \\  - name: auto
        \\
    ;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = try parse(arena, text);
    try testing.expect(doc.problem == null);

    const root = doc.root.asMap().?;
    const proxies = root.get("proxies").?.asList().?;
    try testing.expectEqual(@as(usize, 2), proxies.len);

    // 嵌套 ws-opts.headers
    const p0 = proxies[0].asMap().?;
    try testing.expectEqualSlices(u8, "节点 A", p0.get("name").?.asScalar().?);
    try testing.expectEqualSlices(u8, "p@ss#word", p0.get("password").?.asScalar().?);
    const ws_opts = p0.get("ws-opts").?.asMap().?;
    try testing.expectEqualSlices(u8, "/ws", ws_opts.get("path").?.asScalar().?);
    const headers = ws_opts.get("headers").?.asMap().?;
    try testing.expectEqualSlices(u8, "example.com", headers.get("Host").?.asScalar().?);

    // flow 语法节点
    const p1 = proxies[1].asMap().?;
    try testing.expectEqualSlices(u8, "flow-node", p1.get("name").?.asScalar().?);
    try testing.expectEqualSlices(u8, "vless", p1.get("type").?.asScalar().?);
    // 布尔以原始文本保存
    try testing.expectEqualSlices(u8, "true", p1.get("tls").?.asScalar().?);
}

test "parse anchors and aliases" {
    const text =
        \\proxies:
        \\  - &base
        \\    name: a
        \\    type: ss
        \\    server: 1.2.3.4
        \\    port: 8388
        \\  - *base
        \\
    ;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = try parse(arena, text);
    try testing.expect(doc.problem == null);
    const proxies = doc.root.asMap().?.get("proxies").?.asList().?;
    try testing.expectEqual(@as(usize, 2), proxies.len);
    // 别名解析到同一份内容
    try testing.expectEqualSlices(u8, "a", proxies[1].asMap().?.get("name").?.asScalar().?);
    try testing.expectEqualSlices(u8, "ss", proxies[1].asMap().?.get("type").?.asScalar().?);
}

test "parse failure produces problem" {
    const text = "proxies:\n  - name: [unclosed\n";
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = try parse(arena, text);
    try testing.expect(doc.problem != null);
}

test "invalid alias errors" {
    const text = "proxies:\n  - *undefined\n";
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(error.InvalidAnchor, parse(arena, text));
}
