//! 远程订阅拉取。接口契约由 Wave 0 固定。
//!
//! 数据形状：一次订阅请求的结果是一个 `Response`。它只有四种合法状态，
//! 内容只在 `.ok` 时存在，避免把人机验证页当作 YAML 往下游送。
//!
//! 请求形状对齐 reF1nd/sing-box 的 remote provider：GET、单个 `User-Agent`
//! （默认 `sing-box <version>`）、跟随重定向、只接受 200/304。ETag 缓存与
//! 定时更新不在范围内——这是一次性转换 CLI。

const std = @import("std");

/// reF1nd/sing-box Providers 的默认 User-Agent。
pub const default_user_agent = "sing-box 1.14.0";

pub const Status = enum {
    ok,
    not_modified,
    challenge,
    http_error,
};

pub const Response = struct {
    status: Status,
    /// 已解码的订阅文本。仅 `status == .ok` 时非空。
    content: []const u8,
    http_status: u16,
    /// 从内容首行提取的 subscription-userinfo 文本。
    userinfo: ?[]const u8,
};

pub const Options = struct {
    url: []const u8,
    user_agent: []const u8 = default_user_agent,
    max_redirects: u16 = 5,
    /// 附加请求头，跨重定向保留。
    extra_headers: []const std.http.Header = &.{},
};

pub const Error = error{
    InvalidUrl,
    UnsupportedScheme,
    RequestFailed,
    TooManyRedirects,
    OutOfMemory,
    StreamTooLong,
};

pub const SplitUserInfo = struct {
    userinfo: ?[]const u8,
    rest: []const u8,
};

const Payload = struct {
    content: []const u8,
    userinfo: ?[]const u8,
};

const base64_ignored_chars = " \t\r\n";

const userinfo_keys = [_][]const u8{ "upload", "download", "total", "expire" };

const subscription_markers = [_][]const u8{ "proxies:", "port:", "mixed-port:" };

const subscription_schemes = [_][]const u8{
    "ss://",
    "vmess://",
    "trojan://",
    "vless://",
    "hysteria2://",
    "hy2://",
    "socks5://",
};

const challenge_markers = [_][]const u8{
    "just a moment",
    "cf-chl",
    "challenge-platform",
    "cf-turnstile",
    "attention required",
    "checking your browser",
    "verify you are human",
    "人机验证",
    "请稍候",
};

/// GET 订阅链接，按 reF1nd Providers 的规则归一化响应。
/// 离线错误分支的单元测试用 `std.testing.io` 取得 std.Io。
pub fn fetch(allocator: std.mem.Allocator, io: std.Io, options: Options) Error!Response {
    const uri = std.Uri.parse(options.url) catch return error.InvalidUrl;
    if (uri.scheme.len == 0) return error.InvalidUrl;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) {
        return error.UnsupportedScheme;
    }
    if (uri.host == null) return error.InvalidUrl;

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();

    const result = std.http.Client.fetch(&client, .{
        .location = .{ .uri = uri },
        .method = .GET,
        .redirect_behavior = std.http.Client.Request.RedirectBehavior.init(options.max_redirects),
        .headers = .{ .user_agent = .{ .override = options.user_agent } },
        .extra_headers = options.extra_headers,
        .response_writer = &body.writer,
    }) catch |err| return mapFetchError(err);

    const raw = body.written();
    const http_status: u16 = @intCast(@backingInt(result.status));

    switch (result.status) {
        .ok => {
            if (isChallenge(raw)) {
                return .{ .status = .challenge, .content = "", .http_status = http_status, .userinfo = null };
            }
            const payload = try decodePayload(allocator, raw);
            return .{
                .status = .ok,
                .content = payload.content,
                .http_status = http_status,
                .userinfo = payload.userinfo,
            };
        },
        .not_modified => return .{
            .status = .not_modified,
            .content = "",
            .http_status = http_status,
            .userinfo = null,
        },
        else => return .{
            .status = if (isChallenge(raw)) .challenge else .http_error,
            .content = "",
            .http_status = http_status,
            .userinfo = null,
        },
    }
}

fn mapFetchError(err: std.http.Client.FetchError) Error {
    return switch (err) {
        error.UnexpectedCharacter,
        error.InvalidFormat,
        error.InvalidPort,
        error.InvalidHostName,
        error.UriMissingHost,
        => error.InvalidUrl,
        error.UnsupportedUriScheme => error.UnsupportedScheme,
        error.TooManyHttpRedirects,
        error.RedirectRequiresResend,
        error.HttpRedirectLocationMissing,
        error.HttpRedirectLocationOversize,
        error.HttpRedirectLocationInvalid,
        => error.TooManyRedirects,
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.StreamTooLong,
        else => error.RequestFailed,
    };
}

/// 纯函数。识别 Cloudflare / 机场的人机验证 HTML 页。
pub fn isChallenge(body: []const u8) bool {
    const html = std.ascii.findIgnoreCase(body, "<!doctype html") != null or
        std.ascii.findIgnoreCase(body, "<html") != null;
    if (!html) return false;

    for (challenge_markers) |marker| {
        if (std.ascii.findIgnoreCase(body, marker) != null) return true;
    }
    return false;
}

/// 把原始响应体变成订阅文本。两种 upstream 形态都要成立：
/// `upload=...;...\n<base64 YAML>` 与 `<base64 of "upload=...;...\nYAML">`。
/// 顺序：去 BOM/首部空白；splitUserInfo 一次；已是 YAML 或代理 URI 列表则原样返回；
/// 否则尝试 base64（standard / url_safe / 无 padding，容忍空白），失败保留原文；
/// 再 splitUserInfo 一次；再尝试一次 base64；返回最终文本的一份拷贝。
/// `fetch` 的 Response.userinfo 取 splitUserInfo(raw) 的命中结果，没命中为 null。
pub fn decodeBody(allocator: std.mem.Allocator, raw: []const u8) Error![]const u8 {
    const payload = try decodePayload(allocator, raw);
    if (payload.userinfo) |userinfo| allocator.free(userinfo);
    return payload.content;
}

/// 纯函数。分离首行 `upload=...;download=...;total=...;expire=...`。
pub fn splitUserInfo(text: []const u8) SplitUserInfo {
    const line_end = std.mem.findScalar(u8, text, '\n') orelse text.len;
    var line = text[0..line_end];
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    if (!isUserInfoLine(line)) return .{ .userinfo = null, .rest = text };

    const rest_start = if (line_end < text.len) line_end + 1 else text.len;
    return .{ .userinfo = text[0..line.len], .rest = text[rest_start..] };
}

fn decodePayload(allocator: std.mem.Allocator, raw: []const u8) Error!Payload {
    const trimmed = trimLeadingBomAndSpace(raw);
    const first = splitUserInfo(trimmed);

    if (looksLikeSubscription(first.rest)) {
        return .{
            .content = try allocator.dupe(u8, first.rest),
            .userinfo = try dupeOptional(allocator, first.userinfo),
        };
    }

    if (try tryDecodeBase64(allocator, first.rest)) |decoded| {
        defer allocator.free(decoded);
        const second = splitUserInfo(decoded);

        if (looksLikeSubscription(second.rest)) {
            return .{
                .content = try allocator.dupe(u8, second.rest),
                .userinfo = try dupeOptional(allocator, second.userinfo orelse first.userinfo),
            };
        }

        if (try tryDecodeBase64(allocator, second.rest)) |decoded_again| {
            defer allocator.free(decoded_again);
            const third = splitUserInfo(decoded_again);
            return .{
                .content = try allocator.dupe(u8, third.rest),
                .userinfo = try dupeOptional(allocator, third.userinfo orelse second.userinfo orelse first.userinfo),
            };
        }

        return .{
            .content = try allocator.dupe(u8, second.rest),
            .userinfo = try dupeOptional(allocator, second.userinfo orelse first.userinfo),
        };
    }

    return .{
        .content = try allocator.dupe(u8, trimmed),
        .userinfo = try dupeOptional(allocator, first.userinfo),
    };
}

fn dupeOptional(allocator: std.mem.Allocator, text: ?[]const u8) Error!?[]const u8 {
    const value = text orelse return null;
    return try allocator.dupe(u8, value);
}

fn trimLeadingBomAndSpace(raw: []const u8) []const u8 {
    var text = raw;
    if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text = text[3..];
    return std.mem.trimStart(u8, text, " \t\r\n");
}

fn looksLikeSubscription(text: []const u8) bool {
    for (subscription_markers) |marker| {
        if (std.mem.find(u8, text, marker) != null) return true;
    }
    for (subscription_schemes) |scheme| {
        if (std.mem.find(u8, text, scheme) != null) return true;
    }
    return false;
}

fn tryDecodeBase64(allocator: std.mem.Allocator, text: []const u8) Error!?[]u8 {
    const source = std.mem.trim(u8, text, " \t\r\n");
    if (source.len == 0) return null;

    const decoders = [_]std.base64.Base64DecoderWithIgnore{
        std.base64.Base64DecoderWithIgnore.init(std.base64.standard_alphabet_chars, '=', base64_ignored_chars),
        std.base64.Base64DecoderWithIgnore.init(std.base64.url_safe_alphabet_chars, '=', base64_ignored_chars),
        std.base64.Base64DecoderWithIgnore.init(std.base64.standard_alphabet_chars, null, base64_ignored_chars),
        std.base64.Base64DecoderWithIgnore.init(std.base64.url_safe_alphabet_chars, null, base64_ignored_chars),
    };

    for (decoders) |decoder| {
        const buffer = try allocator.alloc(u8, decoder.calcSizeUpperBound(source.len));
        const decoded_len = decoder.decode(buffer, source) catch {
            allocator.free(buffer);
            continue;
        };
        const decoded = buffer[0..decoded_len];
        if (!isPrintableText(decoded)) {
            allocator.free(buffer);
            continue;
        }
        const exact = try allocator.dupe(u8, decoded);
        allocator.free(buffer);
        return exact;
    }

    return null;
}

fn isPrintableText(bytes: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(bytes)) return false;
    for (bytes) |byte| {
        if (byte == 0 or byte == 0x7f) return false;
        if (byte < 0x20 and byte != '\t' and byte != '\n' and byte != '\r') return false;
    }
    return true;
}

fn isUserInfoLine(line: []const u8) bool {
    var index: usize = 0;
    while (index < line.len) : (index += 1) {
        const at_boundary = index == 0 or line[index - 1] == ';' or std.ascii.isWhitespace(line[index - 1]);
        if (!at_boundary) continue;

        for (userinfo_keys) |key| {
            if (!std.mem.startsWith(u8, line[index..], key)) continue;

            var cursor = index + key.len;
            while (cursor < line.len and std.ascii.isWhitespace(line[cursor])) cursor += 1;
            if (cursor == line.len or line[cursor] != '=') continue;

            cursor += 1;
            while (cursor < line.len and std.ascii.isWhitespace(line[cursor])) cursor += 1;
            if (cursor < line.len and line[cursor] == '-') cursor += 1;
            while (cursor < line.len and std.ascii.isDigit(line[cursor])) cursor += 1;

            if (cursor == line.len) return true;
            if (line[cursor] == ';' or std.ascii.isWhitespace(line[cursor])) return true;
        }
    }
    return false;
}

const testing = std.testing;

const sample_yaml = "proxies:\n  - name: a\n    type: ss\n";
const sample_userinfo = "upload=1; download=2; total=3; expire=4";

test "default user agent matches the sing-box providers value" {
    try testing.expectEqualStrings("sing-box 1.14.0", default_user_agent);
}

test "isChallenge detects a cloudflare interstitial" {
    const page =
        "<!DOCTYPE html><html><head><title>Just a moment...</title></head><body>" ++
        "<script src=\"/cdn-cgi/challenge-platform/h/b/orchestrate/chl_page/v1\"></script>" ++
        "</body></html>";
    try testing.expect(isChallenge(page));
}

test "isChallenge detects chinese human verification pages" {
    const page = "<html><body><p>正在进行人机验证，请稍候</p></body></html>";
    try testing.expect(isChallenge(page));
    try testing.expect(isChallenge("<html><body>CHECKING YOUR BROWSER</body></html>"));
    try testing.expect(isChallenge("<!DoCtYpE hTmL><HTML><div>Attention Required!</div></HTML>"));
}

test "isChallenge ignores ordinary subscription bodies" {
    try testing.expect(!isChallenge(sample_yaml));
    try testing.expect(!isChallenge("ss://YWVzLTI1Ni1nY206cHc@1.2.3.4:8388#a\nvmess://eyJ2IjoiMiJ9\n"));
    try testing.expect(!isChallenge("<html><body>hello</body></html>"));
    try testing.expect(!isChallenge(""));
    try testing.expect(!isChallenge("Just a moment... but no html"));
}

test "splitUserInfo extracts the leading subscription userinfo line" {
    const text = sample_userinfo ++ "\nproxies:\n";
    const split = splitUserInfo(text);
    try testing.expectEqualStrings(sample_userinfo, split.userinfo.?);
    try testing.expectEqualStrings("proxies:\n", split.rest);
}

test "splitUserInfo accepts partial keys, negative values and crlf" {
    const text = "download=123; expire=-1\r\nproxies:\n";
    const split = splitUserInfo(text);
    try testing.expectEqualStrings("download=123; expire=-1", split.userinfo.?);
    try testing.expectEqualStrings("proxies:\n", split.rest);

    const only_total = splitUserInfo("total=0\nport: 7890\n");
    try testing.expectEqualStrings("total=0", only_total.userinfo.?);
    try testing.expectEqualStrings("port: 7890\n", only_total.rest);
}

test "splitUserInfo keeps text when the first line is not userinfo" {
    const split = splitUserInfo(sample_yaml);
    try testing.expectEqual(@as(?[]const u8, null), split.userinfo);
    try testing.expectEqualStrings(sample_yaml, split.rest);

    const single = splitUserInfo(sample_userinfo);
    try testing.expectEqualStrings(sample_userinfo, single.userinfo.?);
    try testing.expectEqualStrings("", single.rest);
}

test "splitUserInfo rejects lookalike first lines" {
    try testing.expectEqual(@as(?[]const u8, null), splitUserInfo("upload_files=1\n").userinfo);
    try testing.expectEqual(@as(?[]const u8, null), splitUserInfo("upload\n").userinfo);
    try testing.expectEqual(@as(?[]const u8, null), splitUserInfo("proxy-upload=1\n").userinfo);
    try testing.expectEqual(@as(?[]const u8, null), splitUserInfo("").userinfo);
}

test "decodeBody returns existing clash yaml unchanged" {
    const decoded = try decodeBody(testing.allocator, sample_yaml);
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings(sample_yaml, decoded);
}

test "decodeBody returns a proxy uri list unchanged" {
    const list = "ss://YWVzLTI1Ni1nY206cHc@1.2.3.4:8388#a\ntrojan://pw@1.2.3.5:443#b\n";
    const decoded = try decodeBody(testing.allocator, list);
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings(list, decoded);
}

test "decodeBody decodes standard base64 with padding" {
    const encoded = "cHJveGllczoKICAtIG5hbWU6IGEKICAgIHR5cGU6IHNzCg==";
    var buffer: [std.base64.standard.Encoder.calcSize(sample_yaml.len)]u8 = undefined;
    try testing.expectEqualStrings(encoded, std.base64.standard.Encoder.encode(&buffer, sample_yaml));

    const decoded = try decodeBody(testing.allocator, encoded);
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings(sample_yaml, decoded);
}

test "decodeBody decodes urlsafe base64 without padding" {
    const encoded = "cHJveGllczoKICAtIG5hbWU6IGEKICAgIHR5cGU6IHNzCg";
    var buffer: [std.base64.url_safe_no_pad.Encoder.calcSize(sample_yaml.len)]u8 = undefined;
    try testing.expectEqualStrings(encoded, std.base64.url_safe_no_pad.Encoder.encode(&buffer, sample_yaml));

    const decoded = try decodeBody(testing.allocator, encoded);
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings(sample_yaml, decoded);
}

test "decodeBody decodes urlsafe base64 that uses - and _" {
    const dash_yaml = "proxies:\n  - name: a>\n    type: ss\n";
    const underscore_yaml = "proxies:\n  - name: a?\n    type: ss\n";

    var dash_buffer: [std.base64.url_safe_no_pad.Encoder.calcSize(dash_yaml.len)]u8 = undefined;
    const dash_encoded = std.base64.url_safe_no_pad.Encoder.encode(&dash_buffer, dash_yaml);
    try testing.expect(std.mem.findScalar(u8, dash_encoded, '-') != null);

    var underscore_buffer: [std.base64.url_safe_no_pad.Encoder.calcSize(underscore_yaml.len)]u8 = undefined;
    const underscore_encoded = std.base64.url_safe_no_pad.Encoder.encode(&underscore_buffer, underscore_yaml);
    try testing.expect(std.mem.findScalar(u8, underscore_encoded, '_') != null);

    const decoded_dash = try decodeBody(testing.allocator, dash_encoded);
    defer testing.allocator.free(decoded_dash);
    try testing.expectEqualStrings(dash_yaml, decoded_dash);

    const decoded_underscore = try decodeBody(testing.allocator, underscore_encoded);
    defer testing.allocator.free(decoded_underscore);
    try testing.expectEqualStrings(underscore_yaml, decoded_underscore);
}

test "decodeBody decodes urlsafe base64 with padding" {
    const encoded = "cHJveGllczoKICAtIG5hbWU6IGE-CiAgICB0eXBlOiBzcwo=";
    const decoded = try decodeBody(testing.allocator, encoded);
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings("proxies:\n  - name: a>\n    type: ss\n", decoded);
}

test "decodeBody decodes standard base64 without padding" {
    const encoded = "cHJveGllczoKICAtIG5hbWU6IGEKICAgIHR5cGU6IHNzCg";
    const decoded = try decodeBody(testing.allocator, encoded);
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings(sample_yaml, decoded);
}

test "decodeBody strips a leading userinfo line before decoding" {
    const encoded = "cHJveGllczoKICAtIG5hbWU6IGEKICAgIHR5cGU6IHNzCg==";
    const raw = try std.mem.concat(testing.allocator, u8, &.{ sample_userinfo, "\n", encoded });
    defer testing.allocator.free(raw);

    const decoded = try decodeBody(testing.allocator, raw);
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings(sample_yaml, decoded);
}

test "decodeBody strips a userinfo line that was itself base64 encoded" {
    const inner = try std.mem.concat(testing.allocator, u8, &.{ sample_userinfo, "\n", sample_yaml });
    defer testing.allocator.free(inner);

    const buffer = try testing.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(inner.len));
    defer testing.allocator.free(buffer);
    const encoded = std.base64.standard.Encoder.encode(buffer, inner);

    const decoded = try decodeBody(testing.allocator, encoded);
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings(sample_yaml, decoded);
}

test "decodeBody drops a plain userinfo prefix in front of plain yaml" {
    const raw = try std.mem.concat(testing.allocator, u8, &.{ sample_userinfo, "\n", sample_yaml });
    defer testing.allocator.free(raw);

    const decoded = try decodeBody(testing.allocator, raw);
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings(sample_yaml, decoded);
}

test "decodeBody trims a leading bom and whitespace" {
    const decoded = try decodeBody(testing.allocator, "\xEF\xBB\xBF \r\n\t" ++ sample_yaml);
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings(sample_yaml, decoded);
}

test "decodeBody tolerates whitespace inside base64" {
    const wrapped = "cHJveGllczoKICAtIG5hbWU6IGEKICA\n" ++ "gIHR5cGU6IHNzCg==";
    const decoded = try decodeBody(testing.allocator, wrapped);
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings(sample_yaml, decoded);

    const multi_line = "  cHJveGllczoK\r\nICAtIG5hbWU6IGEK\tICAgIHR5cGU6IHNzCg==  ";
    const decoded_multi = try decodeBody(testing.allocator, multi_line);
    defer testing.allocator.free(decoded_multi);
    try testing.expectEqualStrings(sample_yaml, decoded_multi);
}

test "decodeBody keeps text that is neither yaml nor base64" {
    const text = "hello world!";
    const decoded = try decodeBody(testing.allocator, text);
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings(text, decoded);

    const binary = "\x00\x01\x02binary";
    const kept = try decodeBody(testing.allocator, binary);
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings(binary, kept);
}

test "decodeBody copies its input" {
    var raw = try testing.allocator.dupe(u8, sample_yaml);
    defer testing.allocator.free(raw);

    const decoded = try decodeBody(testing.allocator, raw);
    defer testing.allocator.free(decoded);
    raw[0] = 'X';
    try testing.expectEqualStrings(sample_yaml, decoded);
}

test "decodeBody handles an empty body" {
    const decoded = try decodeBody(testing.allocator, "");
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings("", decoded);
}

test "fetch rejects schemes other than http and https without a request" {
    try testing.expectError(error.UnsupportedScheme, fetch(testing.allocator, testing.io, .{
        .url = "ftp://example.com/sub",
    }));
    try testing.expectError(error.UnsupportedScheme, fetch(testing.allocator, testing.io, .{
        .url = "file:///etc/passwd",
    }));
}

test "fetch rejects unparsable urls without a request" {
    try testing.expectError(error.InvalidUrl, fetch(testing.allocator, testing.io, .{
        .url = "http://[invalid",
    }));
    try testing.expectError(error.InvalidUrl, fetch(testing.allocator, testing.io, .{
        .url = "example.com/sub",
    }));
}
