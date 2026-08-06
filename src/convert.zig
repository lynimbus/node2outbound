//! clash 节点 → sing-box outbound 转换。
//!
//! 类型映射（骨架版，覆盖最常见协议）：
//!
//! | clash type  | sing-box type  | 说明 |
//! |-------------|----------------|------|
//! | `ss`        | `shadowsocks`  | cipher → method |
//! | `vmess`     | `vmess`        | uuid / alterId |
//! | `trojan`    | `trojan`       | sni → tls.server_name |
//! | `hysteria2` | `hysteria2`    | sni → tls.server_name |
//! | `vless`     | `vless`        | 基础字段 |
//!
//! 其余类型（ssr / snell / tuic / wireguard / hysteria 等）暂不支持，会跳过并计数。

const std = @import("std");
const yaml = @import("yaml.zig");

/// 转换后的 sing-box outbound（仅本项目覆盖的字段）。
pub const Outbound = struct {
    tag: []const u8,
    out_type: []const u8,
    server: []const u8,
    server_port: u16,
    method: ?[]const u8 = null,
    password: ?[]const u8 = null,
    uuid: ?[]const u8 = null,
    alter_id: u16 = 0,
    tls: bool = false,
    server_name: ?[]const u8 = null,

    pub fn jsonStringify(self: *const Outbound, s: anytype) !void {
        try s.beginObject();
        try s.objectField("type");
        try s.write(self.out_type);
        try s.objectField("tag");
        try s.write(self.tag);
        try s.objectField("server");
        try s.write(self.server);
        try s.objectField("server_port");
        try s.write(self.server_port);
        if (self.method) |m| {
            try s.objectField("method");
            try s.write(m);
        }
        if (self.password) |p| {
            try s.objectField("password");
            try s.write(p);
        }
        if (self.uuid) |u| {
            try s.objectField("uuid");
            try s.write(u);
        }
        if (self.alter_id != 0) {
            try s.objectField("alter_id");
            try s.write(self.alter_id);
        }
        if (self.tls) {
            try s.objectField("tls");
            try s.beginObject();
            try s.objectField("enabled");
            try s.write(true);
            if (self.server_name) |sn| {
                try s.objectField("server_name");
                try s.write(sn);
            }
            try s.endObject();
        }
        try s.endObject();
    }
};

pub const Error = error{
    /// 缺少必填字段（server / port / 协议关键字段）
    MissingField,
    /// port 不是合法数字或超出范围
    InvalidPort,
    OutOfMemory,
};

/// 把解析出的节点转换为 outbounds。
/// `skipped` 输出被跳过（不支持类型）的节点数。
/// 返回的 slice 及其中引用的字符串均指向输入，调用方管理释放。
pub fn convert(
    allocator: std.mem.Allocator,
    nodes: []const yaml.Node,
    skipped: *usize,
) Error![]Outbound {
    var out = std.ArrayList(Outbound).empty;
    errdefer out.deinit(allocator);

    skipped.* = 0;
    for (nodes) |node| {
        convertOne(allocator, node, &out) catch |err| switch (err) {
            error.UnsupportedType => {
                skipped.* += 1;
                continue;
            },
            error.MissingField => return error.MissingField,
            error.InvalidPort => return error.InvalidPort,
            error.OutOfMemory => return error.OutOfMemory,
        };
    }
    return out.toOwnedSlice(allocator);
}

const OneError = Error || error{ UnsupportedType };

fn convertOne(allocator: std.mem.Allocator, node: yaml.Node, out: *std.ArrayList(Outbound)) OneError!void {
    const name = getField(node, "name") orelse return error.MissingField;
    const server = getField(node, "server") orelse return error.MissingField;
    const port_raw = getField(node, "port") orelse return error.MissingField;
    const port = parsePort(port_raw) catch return error.InvalidPort;
    const node_type = getField(node, "type") orelse return error.UnsupportedType;

    var ob = Outbound{
        .tag = name,
        .out_type = undefined,
        .server = server,
        .server_port = port,
    };

    if (std.mem.eql(u8, node_type, "ss") or std.mem.eql(u8, node_type, "shadowsocks")) {
        ob.out_type = "shadowsocks";
        ob.method = getField(node, "cipher");
        ob.password = getField(node, "password");
        if (ob.method == null) return error.MissingField;
    } else if (std.mem.eql(u8, node_type, "vmess")) {
        ob.out_type = "vmess";
        ob.uuid = getField(node, "uuid");
        ob.alter_id = parseIntDefault(getField(node, "alterId"), 0) catch return error.InvalidPort;
        if (ob.uuid == null) return error.MissingField;
    } else if (std.mem.eql(u8, node_type, "trojan")) {
        ob.out_type = "trojan";
        ob.password = getField(node, "password");
        ob.tls = true;
        ob.server_name = getField(node, "sni") orelse getField(node, "servername");
        if (ob.password == null) return error.MissingField;
    } else if (std.mem.eql(u8, node_type, "hysteria2") or std.mem.eql(u8, node_type, "hy2")) {
        ob.out_type = "hysteria2";
        ob.password = getField(node, "password");
        ob.tls = true;
        ob.server_name = getField(node, "sni") orelse getField(node, "server-name");
    } else if (std.mem.eql(u8, node_type, "vless")) {
        ob.out_type = "vless";
        ob.uuid = getField(node, "uuid");
        ob.tls = getField(node, "tls") != null or getField(node, "tls") != null;
        ob.server_name = getField(node, "sni") orelse getField(node, "servername");
        if (ob.uuid == null) return error.MissingField;
    } else {
        return error.UnsupportedType;
    }

    try out.append(allocator, ob);
}

/// 把 outbounds 以 JSON 数组形式写入 writer（末尾带换行）。
pub fn writeOutbounds(writer: *std.Io.Writer, outbounds: []const Outbound) !void {
    try writer.print("{f}\n", .{std.json.fmt(outbounds, .{})});
}

fn getField(node: yaml.Node, key: []const u8) ?[]const u8 {
    for (node.fields) |f| {
        if (std.mem.eql(u8, f.key, key)) return f.value;
    }
    return null;
}

fn parsePort(raw: []const u8) !u16 {
    const n = try std.fmt.parseInt(u16, raw, 10);
    if (n == 0) return error.InvalidPort;
    return n;
}

fn parseIntDefault(raw: ?[]const u8, default: u16) !u16 {
    const r = raw orelse return default;
    return std.fmt.parseInt(u16, r, 10);
}

// ---------- tests ----------

const testing = std.testing;

test "convert ss/trojan/vmess" {
    const nodes = [_]yaml.Node{
        .{ .fields = &.{
            .{ .key = "name", .value = "ss-01" },
            .{ .key = "type", .value = "ss" },
            .{ .key = "server", .value = "1.2.3.4" },
            .{ .key = "port", .value = "8388" },
            .{ .key = "cipher", .value = "aes-256-gcm" },
            .{ .key = "password", .value = "pw" },
        } },
        .{ .fields = &.{
            .{ .key = "name", .value = "trojan-01" },
            .{ .key = "type", .value = "trojan" },
            .{ .key = "server", .value = "2.2.2.2" },
            .{ .key = "port", .value = "443" },
            .{ .key = "password", .value = "tpw" },
            .{ .key = "sni", .value = "example.com" },
        } },
        .{ .fields = &.{
            .{ .key = "name", .value = "vmess-01" },
            .{ .key = "type", .value = "vmess" },
            .{ .key = "server", .value = "3.3.3.3" },
            .{ .key = "port", .value = "10086" },
            .{ .key = "uuid", .value = "abc" },
            .{ .key = "alterId", .value = "1" },
        } },
        .{ .fields = &.{
            .{ .key = "name", .value = "ssr-01" },
            .{ .key = "type", .value = "ssr" },
            .{ .key = "server", .value = "4.4.4.4" },
            .{ .key = "port", .value = "8388" },
        } },
    };

    var skipped: usize = 0;
    const out = try convert(testing.allocator, &nodes, &skipped);
    defer testing.allocator.free(out);

    try testing.expectEqual(@as(usize, 1), skipped);
    try testing.expectEqual(@as(usize, 3), out.len);

    try testing.expectEqualSlices(u8, "shadowsocks", out[0].out_type);
    try testing.expectEqualSlices(u8, "aes-256-gcm", out[0].method.?);
    try testing.expectEqual(@as(u16, 8388), out[0].server_port);

    try testing.expectEqualSlices(u8, "trojan", out[1].out_type);
    try testing.expect(out[1].tls);
    try testing.expectEqualSlices(u8, "example.com", out[1].server_name.?);

    try testing.expectEqualSlices(u8, "vmess", out[2].out_type);
    try testing.expectEqual(@as(u16, 1), out[2].alter_id);
}

test "missing field errors" {
    const nodes = [_]yaml.Node{
        .{ .fields = &.{
            .{ .key = "name", .value = "bad" },
            .{ .key = "type", .value = "ss" },
            .{ .key = "server", .value = "1.2.3.4" },
            // 没有 port
        } },
    };
    var skipped: usize = 0;
    try testing.expectError(error.MissingField, convert(testing.allocator, &nodes, &skipped));
}

test "writeOutbounds json" {
    const out = [_]Outbound{
        .{
            .tag = "ss-01",
            .out_type = "shadowsocks",
            .server = "1.2.3.4",
            .server_port = 8388,
            .method = "aes-256-gcm",
            .password = "pw",
        },
        .{
            .tag = "trojan-01",
            .out_type = "trojan",
            .server = "2.2.2.2",
            .server_port = 443,
            .password = "tpw",
            .tls = true,
            .server_name = "example.com",
        },
    };

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = std.Io.Writer.fromWriter(fbs.writer());
    try writeOutbounds(w, &out);

    const json = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, json, "\"type\":\"shadowsocks\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"tag\":\"ss-01\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"server_port\":8388") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"tls\":{\"enabled\":true,\"server_name\":\"example.com\"}") != null);
}
