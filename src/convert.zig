//! clash 节点 → sing-box outbound 转换。
//!
//! 转换契约（grilling 结论）：
//! - 表达不了的节点特性（未知传输层字段、不支持的插件等）→ 跳过并记录原因，
//!   绝不输出语法合法但线上不通的配置；
//! - 缺必填字段 / 非法端口 → 跳过并记录原因；
//! - tag 重复 → 后缀 `-2` / `-3` 去重（sing-box 要求 tag 唯一）；
//! - 除内存不足外，转换不失败：坏节点只进 skip 列表。

const std = @import("std");
const yaml = @import("yaml.zig");

pub const Error = error{ OutOfMemory };

/// ws/http 传输层的 headers 对象。
pub const StringMap = struct {
    entries: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    pub fn jsonStringify(self: @This(), s: anytype) !void {
        try s.beginObject();
        for (self.entries.keys(), self.entries.values()) |k, v| {
            try s.objectField(k);
            try s.write(v);
        }
        try s.endObject();
    }
};

/// vless reality 的 TLS 参数。
pub const Reality = struct {
    public_key: []const u8,
    short_id: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), s: anytype) !void {
        try s.beginObject();
        try s.objectField("enabled");
        try s.write(true);
        try s.objectField("public_key");
        try s.write(self.public_key);
        if (self.short_id) |sid| {
            try s.objectField("short_id");
            try s.write(sid);
        }
        try s.endObject();
    }
};

/// sing-box 的 `tls` 对象（enabled 恒为 true；字段按需出现）。
pub const Tls = struct {
    server_name: ?[]const u8 = null,
    insecure: bool = false,
    alpn: ?[]const []const u8 = null,
    /// client-fingerprint → utls.fingerprint
    fingerprint: ?[]const u8 = null,
    reality: ?Reality = null,

    pub fn jsonStringify(self: @This(), s: anytype) !void {
        try s.beginObject();
        try s.objectField("enabled");
        try s.write(true);
        if (self.server_name) |sn| {
            try s.objectField("server_name");
            try s.write(sn);
        }
        if (self.insecure) {
            try s.objectField("insecure");
            try s.write(true);
        }
        if (self.alpn) |a| {
            try s.objectField("alpn");
            try s.write(a);
        }
        if (self.fingerprint) |f| {
            try s.objectField("utls");
            try s.beginObject();
            try s.objectField("enabled");
            try s.write(true);
            try s.objectField("fingerprint");
            try s.write(f);
            try s.endObject();
        }
        if (self.reality) |r| {
            try s.objectField("reality");
            try s.write(r);
        }
        try s.endObject();
    }
};

pub const Ws = struct {
    path: []const u8 = "/",
    headers: ?StringMap = null,
    max_early_data: ?u32 = null,
    early_data_header_name: ?[]const u8 = null,

    fn writeFields(self: Ws, s: anytype) !void {
        try s.objectField("path");
        try s.write(self.path);
        if (self.headers) |h| {
            try s.objectField("headers");
            try s.write(h);
        }
        if (self.max_early_data) |m| {
            try s.objectField("max_early_data");
            try s.write(m);
        }
        if (self.early_data_header_name) |n| {
            try s.objectField("early_data_header_name");
            try s.write(n);
        }
    }
};

pub const Grpc = struct {
    service_name: ?[]const u8 = null,

    fn writeFields(self: Grpc, s: anytype) !void {
        if (self.service_name) |n| {
            try s.objectField("service_name");
            try s.write(n);
        }
    }
};

pub const Http = struct {
    path: []const u8 = "/",
    method: ?[]const u8 = null,
    headers: ?StringMap = null,

    fn writeFields(self: Http, s: anytype) !void {
        try s.objectField("path");
        try s.write(self.path);
        if (self.method) |m| {
            try s.objectField("method");
            try s.write(m);
        }
        if (self.headers) |h| {
            try s.objectField("headers");
            try s.write(h);
        }
    }
};

/// 传输层对象。
pub const Transport = union(enum) {
    ws: Ws,
    grpc: Grpc,
    http: Http,

    pub fn jsonStringify(self: Transport, s: anytype) !void {
        try s.beginObject();
        try s.objectField("type");
        try s.write(@tagName(self));
        switch (self) {
            inline else => |v| {
                try v.writeFields(s);
            },
        }
        try s.endObject();
    }
};

pub const Shadowsocks = struct {
    tag: []const u8,
    server: []const u8,
    server_port: u16,
    method: []const u8,
    password: []const u8,
    plugin: ?[]const u8 = null,
    plugin_opts: ?[]const u8 = null,
    transport: ?Transport = null,

    fn writeExtra(self: Shadowsocks, s: anytype) !void {
        try s.objectField("method");
        try s.write(self.method);
        try s.objectField("password");
        try s.write(self.password);
        if (self.plugin) |p| {
            try s.objectField("plugin");
            try s.write(p);
        }
        if (self.plugin_opts) |o| {
            try s.objectField("plugin_opts");
            try s.write(o);
        }
        if (self.transport) |t| {
            try s.objectField("transport");
            try s.write(t);
        }
    }
};

pub const Vmess = struct {
    tag: []const u8,
    server: []const u8,
    server_port: u16,
    uuid: []const u8,
    /// clash cipher → sing-box security（"auto" 省略）
    security: ?[]const u8 = null,
    alter_id: ?u16 = null,
    tls: ?Tls = null,
    transport: ?Transport = null,

    fn writeExtra(self: Vmess, s: anytype) !void {
        try s.objectField("uuid");
        try s.write(self.uuid);
        if (self.security) |sec| {
            try s.objectField("security");
            try s.write(sec);
        }
        if (self.alter_id) |aid| {
            try s.objectField("alter_id");
            try s.write(aid);
        }
        if (self.tls) |t| {
            try s.objectField("tls");
            try s.write(t);
        }
        if (self.transport) |t| {
            try s.objectField("transport");
            try s.write(t);
        }
    }
};

pub const Trojan = struct {
    tag: []const u8,
    server: []const u8,
    server_port: u16,
    password: []const u8,
    /// trojan 协议强制 TLS，始终输出 tls 块
    tls: Tls,
    transport: ?Transport = null,

    fn writeExtra(self: Trojan, s: anytype) !void {
        try s.objectField("password");
        try s.write(self.password);
        try s.objectField("tls");
        try s.write(self.tls);
        if (self.transport) |t| {
            try s.objectField("transport");
            try s.write(t);
        }
    }
};

pub const Hysteria2 = struct {
    tag: []const u8,
    server: []const u8,
    server_port: u16,
    password: []const u8,
    obfs: ?Obfs = null,
    up_mbps: ?u64 = null,
    down_mbps: ?u64 = null,
    tls: ?Tls = null,

    fn writeExtra(self: Hysteria2, s: anytype) !void {
        try s.objectField("password");
        try s.write(self.password);
        if (self.obfs) |o| {
            try s.objectField("obfs");
            try s.write(o);
        }
        if (self.up_mbps) |m| {
            try s.objectField("up_mbps");
            try s.write(m);
        }
        if (self.down_mbps) |m| {
            try s.objectField("down_mbps");
            try s.write(m);
        }
        if (self.tls) |t| {
            try s.objectField("tls");
            try s.write(t);
        }
    }
};

pub const Obfs = struct {
    password: []const u8,

    pub fn jsonStringify(self: @This(), s: anytype) !void {
        try s.beginObject();
        try s.objectField("type");
        try s.write("salamander");
        try s.objectField("password");
        try s.write(self.password);
        try s.endObject();
    }
};

pub const Vless = struct {
    tag: []const u8,
    server: []const u8,
    server_port: u16,
    uuid: []const u8,
    flow: ?[]const u8 = null,
    tls: ?Tls = null,
    transport: ?Transport = null,

    fn writeExtra(self: Vless, s: anytype) !void {
        try s.objectField("uuid");
        try s.write(self.uuid);
        if (self.flow) |f| {
            try s.objectField("flow");
            try s.write(f);
        }
        if (self.tls) |t| {
            try s.objectField("tls");
            try s.write(t);
        }
        if (self.transport) |t| {
            try s.objectField("transport");
            try s.write(t);
        }
    }
};

/// 转换后的 sing-box outbound。
/// 序列化为 `{"type": <sing-box 类型>, "tag": ..., "server": ..., "server_port": ...}`。
pub const Outbound = union(enum) {
    shadowsocks: Shadowsocks,
    vmess: Vmess,
    trojan: Trojan,
    hysteria2: Hysteria2,
    vless: Vless,

    pub fn tag(self: Outbound) []const u8 {
        return switch (self) {
            inline else => |v| v.tag,
        };
    }

    pub fn setTag(self: *Outbound, t: []const u8) void {
        switch (self.*) {
            inline else => |*v| v.tag = t,
        }
    }

    pub fn jsonStringify(self: Outbound, s: anytype) !void {
        try s.beginObject();
        try s.objectField("type");
        try s.write(@tagName(self));
        switch (self) {
            inline else => |v| {
                try s.objectField("tag");
                try s.write(v.tag);
                try s.objectField("server");
                try s.write(v.server);
                try s.objectField("server_port");
                try s.write(v.server_port);
                try v.writeExtra(s);
            },
        }
        try s.endObject();
    }
};

/// 一个被跳过的节点（用于 stderr 报告）。
pub const SkipInfo = struct {
    name: []const u8,
    reason: []const u8,
};

const OneResult = union(enum) {
    outbound: Outbound,
    skip: []const u8,
};

const TransportResult = union(enum) {
    none,
    transport: Transport,
    skip: []const u8,
};

const RealityResult = union(enum) {
    none,
    reality: Reality,
    skip: []const u8,
};

const TlsResult = union(enum) {
    none,
    tls: Tls,
    skip: []const u8,
};

/// 把 proxies 列表转换为 outbounds。
/// 跳过原因与节点名写入 `skipped`；tag 重复自动加 `-2`/`-3` 后缀。
/// 返回的 slice 与其中字符串均为 arena 所有。
pub fn convert(
    arena: std.mem.Allocator,
    proxies: []const yaml.Value,
    skipped: *std.ArrayListUnmanaged(SkipInfo),
) Error![]Outbound {
    var out: std.ArrayListUnmanaged(Outbound) = .empty;
    var seen_tags: std.StringHashMapUnmanaged(void) = .empty;

    for (proxies) |p| {
        const map = p.asMap() orelse {
            try skipped.append(arena, .{ .name = "<非映射节点>", .reason = "节点不是 key/value 映射" });
            continue;
        };
        switch (try convertOne(arena, map)) {
            .outbound => |ob| {
                try out.append(arena, ob);
                const final_tag = try dedupTag(arena, &seen_tags, ob.tag());
                out.items[out.items.len - 1].setTag(final_tag);
            },
            .skip => |reason| {
                const name = getStr(map, "name") orelse "<未命名>";
                try skipped.append(arena, .{ .name = name, .reason = reason });
            },
        }
    }
    return out.toOwnedSlice(arena);
}

fn dedupTag(
    arena: std.mem.Allocator,
    seen: *std.StringHashMapUnmanaged(void),
    base: []const u8,
) Error![]const u8 {
    if (!seen.contains(base)) {
        try seen.put(arena, base, {});
        return base;
    }
    var n: usize = 2;
    while (true) : (n += 1) {
        const candidate = std.fmt.allocPrint(arena, "{s}-{d}", .{ base, n }) catch return error.OutOfMemory;
        if (!seen.contains(candidate)) {
            try seen.put(arena, candidate, {});
            return candidate;
        }
    }
}

fn convertOne(arena: std.mem.Allocator, node: yaml.Map) Error!OneResult {
    const name = getStr(node, "name") orelse return .{ .skip = "缺少 name" };
    if (name.len == 0) return .{ .skip = "name 为空" };
    const server = getStr(node, "server") orelse return .{ .skip = "缺少 server" };
    const port_raw = getStr(node, "port") orelse return .{ .skip = "缺少 port" };
    const port = parsePort(port_raw) orelse
        return .{ .skip = try std.fmt.allocPrint(arena, "无效 port: {s}", .{port_raw}) };
    const node_type = getStr(node, "type") orelse return .{ .skip = "缺少 type" };

    if (std.mem.eql(u8, node_type, "ss") or std.mem.eql(u8, node_type, "shadowsocks")) {
        return convertSs(arena, node, name, server, port);
    } else if (std.mem.eql(u8, node_type, "vmess")) {
        return convertVmess(arena, node, name, server, port);
    } else if (std.mem.eql(u8, node_type, "trojan")) {
        return convertTrojan(arena, node, name, server, port);
    } else if (std.mem.eql(u8, node_type, "hysteria2") or std.mem.eql(u8, node_type, "hy2")) {
        return convertHy2(arena, node, name, server, port);
    } else if (std.mem.eql(u8, node_type, "vless")) {
        return convertVless(arena, node, name, server, port);
    } else {
        return .{ .skip = try std.fmt.allocPrint(arena, "不支持的节点类型: {s}", .{node_type}) };
    }
}

fn convertSs(arena: std.mem.Allocator, node: yaml.Map, name: []const u8, server: []const u8, port: u16) Error!OneResult {
    const method = getStr(node, "cipher") orelse return .{ .skip = "缺少 cipher" };
    const password = getStr(node, "password") orelse return .{ .skip = "缺少 password" };

    var ob = Shadowsocks{
        .tag = name,
        .server = server,
        .server_port = port,
        .method = method,
        .password = password,
    };

    // obfs-local 插件 → plugin/plugin_opts；其余插件表达不了 → 跳过
    if (getStr(node, "plugin")) |plugin| {
        if (std.mem.eql(u8, plugin, "obfs-local")) {
            ob.plugin = "obfs-local";
            const opts = getMap(node, "plugin-opts");
            const mode = if (opts) |o| getStr(o, "mode") orelse "http" else "http";
            if (!std.mem.eql(u8, mode, "http") and !std.mem.eql(u8, mode, "tls")) {
                return .{ .skip = try std.fmt.allocPrint(arena, "不支持的 obfs-local mode: {s}", .{mode}) };
            }
            const host = if (opts) |o| getStr(o, "host") else null;
            ob.plugin_opts = if (host) |h|
                try std.fmt.allocPrint(arena, "obfs={s};obfs-host={s}", .{ mode, h })
            else
                try std.fmt.allocPrint(arena, "obfs={s}", .{mode});
        } else {
            return .{ .skip = try std.fmt.allocPrint(arena, "不支持的 ss 插件: {s}", .{plugin}) };
        }
    }

    switch (try convertTransport(arena, node, false)) {
        .none => {},
        .transport => |t| ob.transport = t,
        .skip => |reason| return .{ .skip = reason },
    }

    return .{ .outbound = .{ .shadowsocks = ob } };
}

fn convertVmess(arena: std.mem.Allocator, node: yaml.Map, name: []const u8, server: []const u8, port: u16) Error!OneResult {
    const uuid = getStr(node, "uuid") orelse return .{ .skip = "缺少 uuid" };

    var ob = Vmess{
        .tag = name,
        .server = server,
        .server_port = port,
        .uuid = uuid,
    };
    if (getStr(node, "cipher")) |cipher| {
        if (!std.mem.eql(u8, cipher, "auto")) ob.security = cipher;
    }
    if (getStr(node, "alterId")) |aid_raw| {
        if (aid_raw.len > 0) {
            const aid = std.fmt.parseInt(u16, aid_raw, 10) catch return .{ .skip = "无效 alterId" };
            if (aid != 0) ob.alter_id = aid;
        }
    }

    switch (try convertTls(arena, node, false, null)) {
        .none => {},
        .tls => |t| ob.tls = t,
        .skip => |reason| return .{ .skip = reason },
    }
    switch (try convertTransport(arena, node, false)) {
        .none => {},
        .transport => |t| ob.transport = t,
        .skip => |reason| return .{ .skip = reason },
    }

    return .{ .outbound = .{ .vmess = ob } };
}

fn convertTrojan(arena: std.mem.Allocator, node: yaml.Map, name: []const u8, server: []const u8, port: u16) Error!OneResult {
    const password = getStr(node, "password") orelse return .{ .skip = "缺少 password" };

    var ob = Trojan{
        .tag = name,
        .server = server,
        .server_port = port,
        .password = password,
        .tls = .{},
    };
    switch (try convertTls(arena, node, true, null)) {
        .none => {}, // force=true 时不会发生
        .tls => |t| ob.tls = t,
        .skip => |reason| return .{ .skip = reason },
    }
    switch (try convertTransport(arena, node, false)) {
        .none => {},
        .transport => |t| ob.transport = t,
        .skip => |reason| return .{ .skip = reason },
    }

    return .{ .outbound = .{ .trojan = ob } };
}

fn convertHy2(arena: std.mem.Allocator, node: yaml.Map, name: []const u8, server: []const u8, port: u16) Error!OneResult {
    const password = getStr(node, "password") orelse return .{ .skip = "缺少 password" };

    var ob = Hysteria2{
        .tag = name,
        .server = server,
        .server_port = port,
        .password = password,
    };

    // obfs（salamander）
    if (getStr(node, "obfs")) |obfs_type| {
        if (std.mem.eql(u8, obfs_type, "salamander")) {
            const obfs_pw = getStr(node, "obfs-password") orelse
                return .{ .skip = "obfs 为 salamander 但缺少 obfs-password" };
            ob.obfs = .{ .password = obfs_pw };
        } else {
            return .{ .skip = try std.fmt.allocPrint(arena, "不支持的 hy2 obfs: {s}", .{obfs_type}) };
        }
    }

    // up/down 带宽提示：解析失败仅忽略（不影响连通性）
    if (getStr(node, "up")) |up| {
        ob.up_mbps = std.fmt.parseInt(u64, up, 10) catch null;
    }
    if (getStr(node, "down")) |down| {
        ob.down_mbps = std.fmt.parseInt(u64, down, 10) catch null;
    }

    switch (try convertTls(arena, node, false, null)) {
        .none => {},
        .tls => |t| ob.tls = t,
        .skip => |reason| return .{ .skip = reason },
    }

    return .{ .outbound = .{ .hysteria2 = ob } };
}

fn convertVless(arena: std.mem.Allocator, node: yaml.Map, name: []const u8, server: []const u8, port: u16) Error!OneResult {
    const uuid = getStr(node, "uuid") orelse return .{ .skip = "缺少 uuid" };

    var ob = Vless{
        .tag = name,
        .server = server,
        .server_port = port,
        .uuid = uuid,
    };
    if (getStr(node, "flow")) |f| ob.flow = f;

    var reality: ?Reality = null;
    switch (try convertReality(arena, node)) {
        .none => {},
        .reality => |r| reality = r,
        .skip => |reason| return .{ .skip = reason },
    }
    switch (try convertTls(arena, node, false, reality)) {
        .none => {},
        .tls => |t| ob.tls = t,
        .skip => |reason| return .{ .skip = reason },
    }
    // vless 支持 ws early data
    switch (try convertTransport(arena, node, true)) {
        .none => {},
        .transport => |t| ob.transport = t,
        .skip => |reason| return .{ .skip = reason },
    }

    return .{ .outbound = .{ .vless = ob } };
}

fn convertTransport(arena: std.mem.Allocator, node: yaml.Map, comptime allow_early_data: bool) Error!TransportResult {
    const network = getStr(node, "network") orelse return .none;
    if (std.mem.eql(u8, network, "tcp")) return .none;
    if (std.mem.eql(u8, network, "ws")) return convertWs(arena, node, allow_early_data);
    if (std.mem.eql(u8, network, "grpc")) return convertGrpc(arena, node);
    if (std.mem.eql(u8, network, "http") or std.mem.eql(u8, network, "h2")) return convertHttp(arena, node);
    return .{ .skip = try std.fmt.allocPrint(arena, "不支持的 network: {s}", .{network}) };
}

fn convertWs(arena: std.mem.Allocator, node: yaml.Map, comptime allow_early_data: bool) Error!TransportResult {
    var ws = Ws{};

    if (getMap(node, "ws-opts")) |opts| {
        for (opts.keys()) |k| {
            if (!isKnownWsKey(k)) {
                return .{ .skip = try std.fmt.allocPrint(arena, "ws-opts 不支持的字段: {s}", .{k}) };
            }
        }
        if (getBool(opts, "v2ray-http-upgrade") orelse false) {
            return .{ .skip = "ws-opts 使用 v2ray-http-upgrade（httpupgrade 传输暂不支持）" };
        }
        if (getStr(opts, "path")) |p| ws.path = p;
        if (getMap(opts, "headers")) |hdrs| ws.headers = try extractHeaders(arena, hdrs);
        if (allow_early_data) {
            if (getStr(opts, "max-early-data")) |m| {
                ws.max_early_data = std.fmt.parseInt(u32, m, 10) catch
                    return .{ .skip = "无效 max-early-data" };
            }
            if (getStr(opts, "early-data-header-name")) |n| ws.early_data_header_name = n;
        }
    } else {
        // 旧式平铺字段
        if (getStr(node, "ws-path")) |p| ws.path = p;
        if (getMap(node, "ws-headers")) |hdrs| ws.headers = try extractHeaders(arena, hdrs);
    }

    return .{ .transport = .{ .ws = ws } };
}

fn isKnownWsKey(k: []const u8) bool {
    return std.mem.eql(u8, k, "path") or
        std.mem.eql(u8, k, "headers") or
        std.mem.eql(u8, k, "max-early-data") or
        std.mem.eql(u8, k, "early-data-header-name") or
        std.mem.eql(u8, k, "v2ray-http-upgrade");
}

fn convertGrpc(arena: std.mem.Allocator, node: yaml.Map) Error!TransportResult {
    var grpc = Grpc{};
    if (getMap(node, "grpc-opts")) |opts| {
        for (opts.keys()) |k| {
            if (!std.mem.eql(u8, k, "grpc-service-name")) {
                return .{ .skip = try std.fmt.allocPrint(arena, "grpc-opts 不支持的字段: {s}", .{k}) };
            }
        }
        grpc.service_name = getStr(opts, "grpc-service-name");
    } else if (getStr(node, "grpc-service-name")) |n| {
        grpc.service_name = n;
    }
    return .{ .transport = .{ .grpc = grpc } };
}

fn convertHttp(arena: std.mem.Allocator, node: yaml.Map) Error!TransportResult {
    var http = Http{};
    if (getMap(node, "http-opts")) |opts| {
        for (opts.keys()) |k| {
            if (!std.mem.eql(u8, k, "path") and
                !std.mem.eql(u8, k, "method") and
                !std.mem.eql(u8, k, "headers"))
            {
                return .{ .skip = try std.fmt.allocPrint(arena, "http-opts 不支持的字段: {s}", .{k}) };
            }
        }
        if (getStr(opts, "path")) |p| http.path = p;
        if (getStr(opts, "method")) |m| http.method = m;
        if (getMap(opts, "headers")) |hdrs| http.headers = try extractHeaders(arena, hdrs);
    }
    return .{ .transport = .{ .http = http } };
}

fn convertReality(arena: std.mem.Allocator, node: yaml.Map) Error!RealityResult {
    const opts = getMap(node, "reality-opts") orelse return .none;
    for (opts.keys()) |k| {
        if (!std.mem.eql(u8, k, "public-key") and
            !std.mem.eql(u8, k, "short-id") and
            !std.mem.eql(u8, k, "server-name"))
        {
            return .{ .skip = try std.fmt.allocPrint(arena, "reality-opts 不支持的字段: {s}", .{k}) };
        }
    }
    const public_key = getStr(opts, "public-key") orelse return .{ .skip = "reality-opts 缺少 public-key" };
    return .{ .reality = .{
        .public_key = public_key,
        .short_id = getStr(opts, "short-id"),
    } };
}

fn convertTls(arena: std.mem.Allocator, node: yaml.Map, force: bool, reality: ?Reality) Error!TlsResult {
    const tls_on = getBool(node, "tls") orelse false;
    const server_name = getStr(node, "sni") orelse
        getStr(node, "servername") orelse
        getStr(node, "server-name") orelse blk: {
        const ropts = getMap(node, "reality-opts") orelse break :blk null;
        break :blk getStr(ropts, "server-name");
    };
    // clash 里 sni / skip-cert-verify / client-fingerprint / alpn 出现即意味着走 TLS
    const has_tls_info = server_name != null or
        (getBool(node, "skip-cert-verify") orelse false) or
        getStr(node, "client-fingerprint") != null or
        getList(node, "alpn") != null;
    if (!force and !tls_on and reality == null and !has_tls_info) return .none;

    var tls = Tls{};
    tls.server_name = server_name;
    if (getBool(node, "skip-cert-verify") orelse false) tls.insecure = true;
    if (getStr(node, "client-fingerprint")) |f| tls.fingerprint = f;
    if (getList(node, "alpn")) |alpn| {
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        for (alpn) |a| {
            const s = a.asScalar() orelse continue;
            try list.append(arena, s);
        }
        tls.alpn = try list.toOwnedSlice(arena);
    }
    tls.reality = reality;
    return .{ .tls = tls };
}

/// ws/http 的 headers map → StringMap；空 map 返回 null。
fn extractHeaders(arena: std.mem.Allocator, hdrs: yaml.Map) Error!?StringMap {
    if (hdrs.count() == 0) return null;
    var hm = StringMap{};
    for (hdrs.keys(), hdrs.values()) |hk, hv| {
        const val = hv.asScalar() orelse continue;
        try hm.entries.put(arena, hk, val);
    }
    if (hm.entries.count() == 0) return null;
    return hm;
}

/// 把 outbounds 以 JSON 数组形式写入 writer（末尾带换行）。
pub fn writeOutbounds(writer: *std.Io.Writer, outbounds: []const Outbound) !void {
    try writer.print("{f}\n", .{std.json.fmt(outbounds, .{})});
}

fn getStr(map: yaml.Map, key: []const u8) ?[]const u8 {
    const v = map.get(key) orelse return null;
    return v.asScalar();
}

fn getBool(map: yaml.Map, key: []const u8) ?bool {
    const v = map.get(key) orelse return null;
    const raw = v.asScalar() orelse return null;
    return parseBool(raw);
}

fn parseBool(raw: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(raw, "true") or
        std.ascii.eqlIgnoreCase(raw, "yes") or
        std.ascii.eqlIgnoreCase(raw, "on")) return true;
    if (std.ascii.eqlIgnoreCase(raw, "false") or
        std.ascii.eqlIgnoreCase(raw, "no") or
        std.ascii.eqlIgnoreCase(raw, "off")) return false;
    return null;
}

fn getMap(map: yaml.Map, key: []const u8) ?yaml.Map {
    const v = map.get(key) orelse return null;
    return v.asMap();
}

fn getList(map: yaml.Map, key: []const u8) ?[]const yaml.Value {
    const v = map.get(key) orelse return null;
    return v.asList();
}

fn parsePort(raw: []const u8) ?u16 {
    const n = std.fmt.parseInt(u16, raw, 10) catch return null;
    if (n == 0) return null;
    return n;
}

// ---------- tests ----------

const testing = std.testing;

/// 解析 YAML 文本并转换，返回 outbounds。
fn convertText(
    arena: std.mem.Allocator,
    text: []const u8,
    skipped: *std.ArrayListUnmanaged(SkipInfo),
) ![]Outbound {
    const doc = try yaml.parse(arena, text);
    try testing.expect(doc.problem == null);
    const proxies = doc.root.asMap().?.get("proxies").?.asList().?;
    return try convert(arena, proxies, skipped);
}

/// 把 outbounds 序列化为 JSON 字符串（用于子串断言）。
fn jsonOf(arena: std.mem.Allocator, out: []const Outbound) ![]const u8 {
    var buf: [16384]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = std.Io.Writer.fromWriter(fbs.writer());
    try writeOutbounds(w, out);
    return try arena.dupe(u8, fbs.getWritten());
}

test "ss with ws transport and headers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text =
        \\proxies:
        \\  - name: ss-ws
        \\    type: ss
        \\    server: 1.2.3.4
        \\    port: 8388
        \\    cipher: aes-256-gcm
        \\    password: pw
        \\    network: ws
        \\    ws-opts:
        \\      path: /v2
        \\      headers:
        \\        Host: cdn.example.com
        \\
    ;
    var skipped: std.ArrayListUnmanaged(SkipInfo) = .empty;
    const out = try convertText(arena, text, &skipped);
    try testing.expectEqual(@as(usize, 0), skipped.items.len);
    try testing.expectEqual(@as(usize, 1), out.len);

    const json = try jsonOf(arena, out);
    try testing.expect(std.mem.indexOf(u8, json, "\"type\":\"shadowsocks\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"transport\":{\"type\":\"ws\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"path\":\"/v2\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"headers\":{\"Host\":\"cdn.example.com\"}") != null);
}

test "vless reality with flow and ws early data" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text =
        \\proxies:
        \\  - name: vl-reality
        \\    type: vless
        \\    server: example.com
        \\    port: 443
        \\    uuid: 11111111-2222-3333-4444-555555555555
        \\    network: ws
        \\    tls: true
        \\    sni: example.com
        \\    flow: xtls-rprx-vision
        \\    client-fingerprint: chrome
        \\    ws-opts:
        \\      path: /?ed=2048
        \\      max-early-data: 2048
        \\      early-data-header-name: Sec-WebSocket-Protocol
        \\    reality-opts:
        \\      public-key: abcdef1234567890
        \\      short-id: abcd1234
        \\
    ;
    var skipped: std.ArrayListUnmanaged(SkipInfo) = .empty;
    const out = try convertText(arena, text, &skipped);
    try testing.expectEqual(@as(usize, 0), skipped.items.len);
    try testing.expectEqual(@as(usize, 1), out.len);

    const json = try jsonOf(arena, out);
    try testing.expect(std.mem.indexOf(u8, json, "\"type\":\"vless\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"flow\":\"xtls-rprx-vision\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"reality\":{\"enabled\":true,\"public_key\":\"abcdef1234567890\",\"short_id\":\"abcd1234\"}") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"utls\":{\"enabled\":true,\"fingerprint\":\"chrome\"}") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"max_early_data\":2048") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"early_data_header_name\":\"Sec-WebSocket-Protocol\"") != null);
}

test "trojan ws with skip-cert-verify and alpn" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text =
        \\proxies:
        \\  - name: tj
        \\    type: trojan
        \\    server: 2.2.2.2
        \\    port: 443
        \\    password: tpw
        \\    sni: tj.example.com
        \\    skip-cert-verify: true
        \\    alpn:
        \\      - h2
        \\      - http/1.1
        \\    network: ws
        \\    ws-opts:
        \\      path: /tj
        \\
    ;
    var skipped: std.ArrayListUnmanaged(SkipInfo) = .empty;
    const out = try convertText(arena, text, &skipped);
    try testing.expectEqual(@as(usize, 0), skipped.items.len);
    try testing.expectEqual(@as(usize, 1), out.len);

    const json = try jsonOf(arena, out);
    try testing.expect(std.mem.indexOf(u8, json, "\"type\":\"trojan\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"tls\":{\"enabled\":true,\"server_name\":\"tj.example.com\",\"insecure\":true,\"alpn\":[\"h2\",\"http/1.1\"]}") != null);
}

test "hy2 with obfs salamander and bandwidth" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text =
        \\proxies:
        \\  - name: hy
        \\    type: hysteria2
        \\    server: hy.example.com
        \\    port: 443
        \\    password: hpw
        \\    sni: hy.example.com
        \\    obfs: salamander
        \\    obfs-password: obfspw
        \\    up: 50
        \\    down: 200
        \\
    ;
    var skipped: std.ArrayListUnmanaged(SkipInfo) = .empty;
    const out = try convertText(arena, text, &skipped);
    try testing.expectEqual(@as(usize, 0), skipped.items.len);
    try testing.expectEqual(@as(usize, 1), out.len);

    const json = try jsonOf(arena, out);
    try testing.expect(std.mem.indexOf(u8, json, "\"type\":\"hysteria2\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"obfs\":{\"type\":\"salamander\",\"password\":\"obfspw\"}") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"up_mbps\":50") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"down_mbps\":200") != null);
}

test "ss obfs-local plugin maps to plugin_opts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text =
        \\proxies:
        \\  - name: ss-obfs
        \\    type: ss
        \\    server: 1.2.3.4
        \\    port: 8388
        \\    cipher: aes-256-cfb
        \\    password: pw
        \\    plugin: obfs-local
        \\    plugin-opts:
        \\      mode: tls
        \\      host: cdn.example.com
        \\
    ;
    var skipped: std.ArrayListUnmanaged(SkipInfo) = .empty;
    const out = try convertText(arena, text, &skipped);
    try testing.expectEqual(@as(usize, 0), skipped.items.len);

    const json = try jsonOf(arena, out);
    try testing.expect(std.mem.indexOf(u8, json, "\"plugin\":\"obfs-local\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"plugin_opts\":\"obfs=tls;obfs-host=cdn.example.com\"") != null);
}

test "unexpressible features are skipped with reasons" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text =
        \\proxies:
        \\  - name: v2ray-plugin
        \\    type: ss
        \\    server: 1.2.3.4
        \\    port: 8388
        \\    cipher: aes-256-gcm
        \\    password: pw
        \\    plugin: v2ray-plugin
        \\  - name: unknown-network
        \\    type: vmess
        \\    server: 1.2.3.4
        \\    port: 443
        \\    uuid: u
        \\    network: kcp
        \\  - name: weird-ws-opts
        \\    type: vless
        \\    server: 1.2.3.4
        \\    port: 443
        \\    uuid: u
        \\    network: ws
        \\    ws-opts:
        \\      path: /x
        \\      headers:
        \\        Host: a
        \\      early-data-header-name: y
        \\      packet-encoding: xudp
        \\  - name: bad-port
        \\    type: ss
        \\    server: 1.2.3.4
        \\    port: 99999
        \\    cipher: aes-256-gcm
        \\    password: pw
        \\  - name: no-password-hy2
        \\    type: hysteria2
        \\    server: 1.2.3.4
        \\    port: 443
        \\    sni: a
        \\  - name: ssr-node
        \\    type: ssr
        \\    server: 1.2.3.4
        \\    port: 8388
        \\
    ;
    var skipped: std.ArrayListUnmanaged(SkipInfo) = .empty;
    const out = try convertText(arena, text, &skipped);
    try testing.expectEqual(@as(usize, 0), out.len);
    try testing.expectEqual(@as(usize, 6), skipped.items.len);

    try testing.expectEqualSlices(u8, "v2ray-plugin", skipped.items[0].name);
    try testing.expect(std.mem.indexOf(u8, skipped.items[0].reason, "v2ray-plugin") != null);
    try testing.expectEqualSlices(u8, "unknown-network", skipped.items[1].name);
    try testing.expect(std.mem.indexOf(u8, skipped.items[1].reason, "kcp") != null);
    try testing.expectEqualSlices(u8, "weird-ws-opts", skipped.items[2].name);
    try testing.expect(std.mem.indexOf(u8, skipped.items[2].reason, "packet-encoding") != null);
    try testing.expectEqualSlices(u8, "bad-port", skipped.items[3].name);
    try testing.expectEqualSlices(u8, "no-password-hy2", skipped.items[4].name);
    try testing.expectEqualSlices(u8, "ssr-node", skipped.items[5].name);
}

test "tag dedup appends -2 suffix" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text =
        \\proxies:
        \\  - name: same
        \\    type: ss
        \\    server: 1.2.3.4
        \\    port: 8388
        \\    cipher: aes-256-gcm
        \\    password: a
        \\  - name: same
        \\    type: ss
        \\    server: 5.6.7.8
        \\    port: 8388
        \\    cipher: aes-256-gcm
        \\    password: b
        \\  - name: same-2
        \\    type: ss
        \\    server: 9.9.9.9
        \\    port: 8388
        \\    cipher: aes-256-gcm
        \\    password: c
        \\
    ;
    var skipped: std.ArrayListUnmanaged(SkipInfo) = .empty;
    const out = try convertText(arena, text, &skipped);
    try testing.expectEqual(@as(usize, 0), skipped.items.len);
    try testing.expectEqual(@as(usize, 3), out.len);

    try testing.expectEqualSlices(u8, "same", out[0].tag());
    try testing.expectEqualSlices(u8, "same-2", out[1].tag());
    // 已存在的 same-2 不冲突，第三个顺延为 same-3
    try testing.expectEqualSlices(u8, "same-3", out[2].tag());
}

test "vmess alter_id zero omitted, nonzero kept" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text =
        \\proxies:
        \\  - name: vm0
        \\    type: vmess
        \\    server: 1.2.3.4
        \\    port: 443
        \\    uuid: u
        \\    alterId: 0
        \\  - name: vm64
        \\    type: vmess
        \\    server: 1.2.3.4
        \\    port: 443
        \\    uuid: u
        \\    alterId: 64
        \\
    ;
    var skipped: std.ArrayListUnmanaged(SkipInfo) = .empty;
    const out = try convertText(arena, text, &skipped);
    try testing.expectEqual(@as(usize, 0), skipped.items.len);
    try testing.expectEqual(@as(usize, 2), out.len);

    const json = try jsonOf(arena, out);
    // 只有一条带 alter_id
    try testing.expect(std.mem.indexOf(u8, json, "\"alter_id\":64") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"alter_id\":0") == null);
}

test "vless tls false stays plain" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text =
        \\proxies:
        \\  - name: plain
        \\    type: vless
        \\    server: 1.2.3.4
        \\    port: 443
        \\    uuid: u
        \\    tls: false
        \\
    ;
    var skipped: std.ArrayListUnmanaged(SkipInfo) = .empty;
    const out = try convertText(arena, text, &skipped);
    try testing.expectEqual(@as(usize, 0), skipped.items.len);

    const json = try jsonOf(arena, out);
    try testing.expect(std.mem.indexOf(u8, json, "\"tls\"") == null);
}

test "hy2 without tls info emits no tls block" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text =
        \\proxies:
        \\  - name: hy-plain
        \\    type: hysteria2
        \\    server: 1.2.3.4
        \\    port: 443
        \\    password: pw
        \\
    ;
    var skipped: std.ArrayListUnmanaged(SkipInfo) = .empty;
    const out = try convertText(arena, text, &skipped);
    try testing.expectEqual(@as(usize, 0), skipped.items.len);

    const json = try jsonOf(arena, out);
    try testing.expect(std.mem.indexOf(u8, json, "\"tls\"") == null);
}

test "hy2 with sni emits tls block even without tls flag" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text =
        \\proxies:
        \\  - name: hy-sni
        \\    type: hysteria2
        \\    server: 1.2.3.4
        \\    port: 443
        \\    password: pw
        \\    sni: hy.example.com
        \\
    ;
    var skipped: std.ArrayListUnmanaged(SkipInfo) = .empty;
    const out = try convertText(arena, text, &skipped);
    try testing.expectEqual(@as(usize, 0), skipped.items.len);

    const json = try jsonOf(arena, out);
    try testing.expect(std.mem.indexOf(u8, json, "\"tls\":{\"enabled\":true,\"server_name\":\"hy.example.com\"}") != null);
}
