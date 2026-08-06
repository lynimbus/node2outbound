//! Clash 配置文件中 `proxies:` 区块的轻量解析器。
//!
//! 只解析本项目需要的 YAML 子集（clash 订阅/配置中常见的节点列表形态）：
//!
//! ```yaml
//! proxies:
//!   - name: "节点 A"        # 行内注释
//!     type: ss
//!     server: 1.2.3.4
//!     port: 8388
//!     cipher: aes-256-gcm
//!     password: 'secret'
//! ```
//!
//! 支持：缩进列表、`- name: x` 行内首字段、单/双引号、行尾注释、`\r\n` 换行。
//! 不支持：锚点/别名、内联 flow 语法、多行值、块标量、tab 缩进。
//!
//! 所有返回的 key/value 都指向原始输入文本，调用方需保证其生命周期。

const std = @import("std");

/// 节点的一个字段（如 `name: "节点 A"`）。
pub const Field = struct {
    key: []const u8,
    /// 已去除引号与首尾空白
    value: []const u8,
};

/// 一个节点（proxies 列表中的一项）。
pub const Node = struct {
    fields: []Field,
};

pub const Error = error{
    /// 输入里没有找到 `proxies:` 区块
    MissingProxies,
    OutOfMemory,
};

/// 解析 clash 文本，返回所有节点。
/// `text` 的生命周期必须覆盖返回结果。
pub fn parseProxies(allocator: std.mem.Allocator, text: []const u8) Error![]Node {
    var nodes = std.ArrayList(Node).empty;
    errdefer {
        for (nodes.items) |n| allocator.free(n.fields);
        nodes.deinit(allocator);
    }

    var current_fields: ?std.ArrayList(Field) = null;
    var in_proxies = false;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        // 去掉 \r（Windows 换行）
        const line = std.mem.trimEnd(u8, raw, "\r");
        // 剥离引号外的行尾注释
        const content = stripComment(line);
        const trimmed = std.mem.trim(u8, content, " \t");
        if (trimmed.len == 0) continue;

        const indent = leadingSpaces(content);

        if (!in_proxies) {
            if (indent == 0 and isProxiesHeader(trimmed)) in_proxies = true;
            continue;
        }

        // 遇到下一个顶层 key（缩进 0），proxies 区块结束
        if (indent == 0) break;

        // 缩进 2 的 `- ...` 开始一个新节点
        if (indent == 2 and trimmed[0] == '-') {
            try commitNode(allocator, &nodes, &current_fields);
            current_fields = std.ArrayList(Field).empty;
            const rest = std.mem.trimStart(u8, trimmed[1..], " \t");
            if (rest.len > 0) try appendField(allocator, &current_fields.?, rest);
            continue;
        }

        // 缩进 4 的 `key: value` 属于当前节点
        if (indent == 4 and current_fields != null) {
            try appendField(allocator, &current_fields.?, trimmed);
            continue;
        }

        // 其他缩进（2 但非 `-`、4 但无当前节点等）：忽略
    }

    // 收尾：提交最后一个节点
    try commitNode(allocator, &nodes, &current_fields);
    if (current_fields) |*list| list.deinit(allocator);

    if (nodes.items.len == 0) return error.MissingProxies;
    return nodes.toOwnedSlice(allocator);
}

/// 把 current_fields 作为节点提交（非空时）。
fn commitNode(
    allocator: std.mem.Allocator,
    nodes: *std.ArrayList(Node),
    current: *?std.ArrayList(Field),
) Error!void {
    if (current.* == null) return;
    const list = &current.*.?;
    if (list.items.len == 0) return;
    try nodes.append(allocator, .{ .fields = try list.toOwnedSlice(allocator) });
    current.* = null;
}

/// 解析一行 `key: value`，追加为字段。
fn appendField(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(Field),
    line: []const u8,
) Error!void {
    const colon = findSplitColon(line) orelse return; // 无冒号，忽略
    const key = std.mem.trim(u8, line[0..colon], " \t");
    if (key.len == 0) return;
    const value = unquote(std.mem.trim(u8, line[colon + 1 ..], " \t"));
    try list.append(allocator, .{ .key = key, .value = value });
}

/// 找到分隔 `key: value` 的冒号位置：冒号后须为空白或行尾。
/// 返回行内第一个满足条件的冒号。
fn findSplitColon(line: []const u8) ?usize {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == ':') {
            if (i + 1 == line.len or line[i + 1] == ' ' or line[i + 1] == '\t') return i;
        }
    }
    return null;
}

/// 是否 `proxies:` 顶层 key。
fn isProxiesHeader(trimmed: []const u8) bool {
    return std.mem.eql(u8, trimmed, "proxies:") or std.mem.startsWith(u8, trimmed, "proxies:");
}

/// 前导空格数（tab 视为 0，本项目不处理 tab 缩进）。
fn leadingSpaces(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and line[n] == ' ') : (n += 1) {}
    return n;
}

/// 剥离引号外的 `#` 注释。
fn stripComment(line: []const u8) []const u8 {
    var quote: u8 = 0;
    for (line, 0..) |c, i| {
        switch (c) {
            '\'', '"' => {
                if (quote == 0)
                    quote = c
                else if (quote == c)
                    quote = 0;
            },
            '#' => if (quote == 0) return line[0..i],
            else => {},
        }
    }
    return line;
}

/// 去掉首尾成对的引号。
fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2) {
        const first = value[0];
        const last = value[value.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
            return value[1 .. value.len - 1];
        }
    }
    return value;
}

// ---------- tests ----------

const testing = std.testing;

test "parse basic proxies" {
    const text =
        \\proxies:
        \\  - name: "节点 A"   # 注释
        \\    type: ss
        \\    server: 1.2.3.4
        \\    port: 8388
        \\    cipher: aes-256-gcm
        \\    password: 'secret'
        \\  - name: trojan-01
        \\    type: trojan
        \\    server: 2.2.2.2
        \\    port: 443
        \\    password: "p@ss#word"
        \\    sni: example.com
        \\proxy-groups:
        \\  - name: auto
        \\
    ;
    const nodes = try parseProxies(testing.allocator, text);
    defer {
        for (nodes) |n| testing.allocator.free(n.fields);
        testing.allocator.free(nodes);
    }

    try testing.expectEqual(@as(usize, 2), nodes.len);
    try testing.expectEqualSlices(u8, "节点 A", getField(nodes[0], "name").?);
    try testing.expectEqualSlices(u8, "8388", getField(nodes[0], "port").?);
    // 注释与引号处理
    try testing.expectEqualSlices(u8, "p@ss#word", getField(nodes[1], "password").?);
    try testing.expectEqualSlices(u8, "trojan-01", getField(nodes[1], "name").?);
}

test "missing proxies errors" {
    try testing.expectError(error.MissingProxies, parseProxies(testing.allocator, "port: 80\n"));
}

test "crlf and empty lines" {
    const text = "proxies:\r\n  - name: a\r\n    type: ss\r\n\r\n";
    const nodes = try parseProxies(testing.allocator, text);
    defer {
        for (nodes) |n| testing.allocator.free(n.fields);
        testing.allocator.free(nodes);
    }
    try testing.expectEqual(@as(usize, 1), nodes.len);
    try testing.expectEqualSlices(u8, "a", getField(nodes[0], "name").?);
}

fn getField(node: Node, key: []const u8) ?[]const u8 {
    for (node.fields) |f| {
        if (std.mem.eql(u8, f.key, key)) return f.value;
    }
    return null;
}
