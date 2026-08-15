# node2outbound

把 [clash](https://github.com/Dreamacro/clash) 配置（订阅链接 / 本地完整配置）中的节点（`proxies:`）转换为 [sing-box](https://github.com/SagerNet/sing-box) `outbounds` 配置的 Zig CLI 工具。

```bash
node2outbound -i clash.yaml -o outbounds.json
cat clash.yaml | node2outbound > outbounds.json
curl -sL "https://example.com/sub" | node2outbound > outbounds.json
```

## 特性

- 纯 Zig 单二进制，无运行时依赖（YAML 解析用 vendored libyaml，MIT，编译进产物）
- 完整 YAML 1.1 解析：嵌套 map（`ws-opts` / `reality-opts` / `headers`）、flow 语法（`- {name: x}`）、锚点/别名、任意缩进、注释、CRLF
- 支持 stdin/stdout 管道，方便与 `jq` 等工具组合
- 传输层与 TLS 细节字段完整映射（见下表）
- 表达不了的节点自动跳过并在 stderr 报告原因，不影响其余节点
- tag 重复自动加 `-2` / `-3` 后缀（sing-box 要求 tag 唯一）

## 构建

需要 Zig 0.17.0 或更新版本：

```bash
zig build -Doptimize=ReleaseSafe
# 产物在 zig-out/bin/node2outbound
```

## 用法

```
node2outbound [-i <clash.yaml>] [-o <outbounds.json>] [-g [组名]]

选项:
  -i, --input <文件>    输入 clash 配置文件（默认读 stdin）
  -o, --output <文件>   输出 sing-box JSON（默认写 stdout）
  -g, --group [组名]    只输出 outbounds 的 tag 列表（JSON 数组），跳过与组名相同的 tag；
                       默认组名 select，便于直接插入 selector 组的 outbounds
  -h, --help            显示帮助并退出
```

示例：

```bash
# 文件到文件
node2outbound -i config.yaml -o outbounds.json

# 订阅链接 → sing-box 配置片段（配合 curl）
curl -sL "https://example.com/sub" | node2outbound > outbounds.json

# 快速导出除 select 外的所有 tag，直接粘进 sing-box selector 组的 outbounds
curl -sL "https://example.com/sub" | node2outbound -g

# 自定义组名：跳过与组名相同的 tag（此处跳过名为 auto 的节点）
cat clash.yaml | node2outbound --group auto
```

输出是一段 JSON 数组，可直接粘到 sing-box 配置的 `outbounds` 字段，或与 `sing-box merge` 组合使用。

## 行为契约

- **跳过策略**：节点使用工具无法表达的协议 / 传输层 / 字段（如 `ssr`、`v2ray-plugin`、未知的 `ws-opts` 键、`network: kcp`）时，该节点被跳过并计数，**绝不输出语法合法但线上不通的配置**。跳过明细（名称 + 原因）写入 stderr。
- **退出码**：`0` = 成功产出 outbounds（部分节点被跳过时仍为 0）；`1` = 硬失败（输入/解析错误，或没有任何节点可转换）。
- **tag 去重**：重复 name 依次追加 `-2`、`-3`……（若 `-2` 已被占用则顺延）。

## 类型映射

| clash type | sing-box type | 字段映射 |
|------------|---------------|----------|
| `ss` / `shadowsocks` | `shadowsocks` | `cipher` → `method`，`password`，`plugin: obfs-local` → `plugin` + `plugin_opts`（`obfs=http/tls;obfs-host=…`） |
| `vmess` | `vmess` | `uuid`，`cipher`（非 auto）→ `security`，`alterId`（非 0）→ `alter_id` |
| `trojan` | `trojan` | `password`，恒输出 `tls` 块 |
| `hysteria2` / `hy2` | `hysteria2` | `password`（必填），`obfs: salamander` → `obfs`，`up`/`down` → `up_mbps`/`down_mbps` |
| `vless` | `vless` | `uuid`，`flow`（如 `xtls-rprx-vision`） |

### 传输层（`network`）

| clash network | sing-box transport |
|---------------|--------------------|
| `ws` | `ws`：`ws-opts.path` → `path`，`ws-opts.headers` → `headers`，`ws-opts.max-early-data` / `early-data-header-name` → `max_early_data` / `early_data_header_name`（vless），旧式平铺 `ws-path` / `ws-headers` 同样支持 |
| `grpc` | `grpc`：`grpc-opts.grpc-service-name` → `service_name` |
| `http` / `h2` | `http`：`http-opts.path` / `method` / `headers` |

### TLS 与安全

- `sni` / `servername` / `server-name` → `tls.server_name`；`skip-cert-verify` → `tls.insecure`
- `client-fingerprint` → `tls.utls.fingerprint`；`alpn` → `tls.alpn`
- vless `reality-opts.public-key` / `short-id` → `tls.reality`（`reality-opts.server-name` 并入 `server_name`）

### 跳过（不支持的节点特性）

`ssr`、`snell`、`tuic`、`wireguard`、`hysteria`，`ss` 的 `v2ray-plugin` 等插件，`network: kcp` 等未知传输，`ws-opts.v2ray-http-upgrade`，以及 ws/grpc/http/reality opts 中的未知字段——一律跳过并报告。

## Roadmap

- [ ] `ssr`、`tuic`、`hysteria`、`wireguard`、`snell` 支持
- [ ] `ws-opts.v2ray-http-upgrade`（httpupgrade 传输）
- [ ] 输出为完整 sing-box 配置模板（含 proxy-groups 转换）

## 相关项目

- [sing-box](https://github.com/SagerNet/sing-box) — 通用代理平台
- [clash2singbox](https://github.com/xmdhs/clash2singbox) — 同思路的 Rust 实现（功能更全）

## License

MIT（vendored libyaml 亦为 MIT，见 `vendor/libyaml/LICENSE`）
