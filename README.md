# node2outbound

把 [clash](https://github.com/Dreamacro/clash) 配置文件中的节点（`proxies:`）转换为 [sing-box](https://github.com/SagerNet/sing-box) `outbounds` 配置的 Zig CLI 工具。

```bash
node2outbound -i clash.yaml -o outbounds.json
cat clash.yaml | node2outbound > outbounds.json
```

## 特性

- 纯 Zig 实现，无运行时依赖，单二进制
- 零第三方库：自带轻量 YAML 子集解析器（只解析本项目需要的部分）
- 支持 stdin/stdout 管道，方便与 `jq` 等工具组合
- 不支持的节点类型自动跳过并提示，不影响其余节点

## 构建

需要 Zig 0.17.0 或更新版本：

```bash
zig build -Doptimize=ReleaseSafe
# 产物在 zig-out/bin/node2outbound
```

## 用法

```
node2outbound [-i <clash.yaml>] [-o <outbounds.json>]

选项:
  -i, --input <文件>    输入 clash 配置文件（默认读 stdin）
  -o, --output <文件>   输出 sing-box JSON（默认写 stdout）
  -h, --help            显示帮助并退出
```

示例：

```bash
# 文件到文件
node2outbound -i config.yaml -o outbounds.json

# 订阅链接 → sing-box 配置片段（配合 curl）
curl -sL "https://example.com/sub" | node2outbound > outbounds.json

# 只提取 tag，方便和 jq 组合
cat clash.yaml | node2outbound | jq -r '.[].tag'
```

输出是一段 JSON 数组，可直接粘到 sing-box 配置的 `outbounds` 字段，或与 `sing-box merge` 组合使用。

## 类型映射

| clash type | sing-box type | 字段映射 |
|------------|---------------|----------|
| `ss` | `shadowsocks` | `cipher` → `method`，`password` |
| `vmess` | `vmess` | `uuid`，`alterId` → `alter_id` |
| `trojan` | `trojan` | `password`，`sni` → `tls.server_name` |
| `hysteria2` / `hy2` | `hysteria2` | `password`，`sni` → `tls.server_name` |
| `vless` | `vless` | `uuid`，`tls` / `sni` |

暂不支持（会跳过并计数）：`ssr`、`snell`、`tuic`、`wireguard`、`hysteria` 以及 `ws-opts` / `network` / `client-fingerprint` 等传输层细节字段。

## Roadmap

- [ ] 传输层字段（`ws` / `grpc` / `http` 的 `ws-opts` 等）
- [ ] `ssr`、`tuic`、`hysteria` 支持
- [ ] sing-box `tag` 去重 / 前缀规范化
- [ ] 输出为完整 sing-box 配置模板（而非仅 outbounds 数组）

## 相关项目

- [sing-box](https://github.com/SagerNet/sing-box) — 通用代理平台
- [clash2singbox](https://github.com/xmdhs/clash2singbox) — 同思路的 Rust 实现（功能更全）

## License

MIT
