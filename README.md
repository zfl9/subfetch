# subfetch

订阅拉取 & 多格式配置生成工具：抓取订阅节点，生成 clash / sing-box / 原生客户端的配置文件，安装前真实校验，安装后自动重载。

单二进制、零运行时依赖，适合服务器 / 路由器上 cron 定时运行。

## 特性

- 8 种协议解析：ss / ssr / vmess / vless(+reality) / trojan / hysteria / hysteria2 / tuic
- 订阅格式自动识别：URI 列表、base64、clash YAML、v2rayN JSON、sing-box JSON
- 9 种输出格式：clash / sing-box 聚合配置，ss / ssr / trojan / xray / hysteria / hysteria2 原生配置，raw 节点列表
- 安装前用真实客户端校验（`mihomo -t`、`sing-box check`、`xray -test`），校验失败不动旧配置
- 安装后热重载（API 优先，失败回退 systemctl，也可自定义命令）
- 机场通知节点（到期 / 流量提示）自动过滤，关键词可配置
- `.zon` 类型安全配置，字段拼错直接报错

## 快速开始

```sh
# 1. 复制配置模板
cp subscriptions.example.zon subscriptions.zon
vim subscriptions.zon

# 2. 预览（不写文件，输出到 stdout）
subfetch -c subscriptions.zon -o clash=- --dry-run

# 3. 正式安装并重载
subfetch -c subscriptions.zon -o clash=/etc/clash/config.yaml \
    --reload-cmd "systemctl restart clash"

# 4. 多个输出目标（一次运行）
subfetch -c subscriptions.zon \
    -o clash=/etc/clash/config.yaml \
    -o singbox=/etc/sing-box/config.json
```

## 配置

```zig
.{
    .ua = "clash-verge/v2.2.3",   // 默认 User-Agent
    .subscriptions = .{
        .{
            .name = "香港机场",          // 订阅名，作为节点名前缀（≤32 字节）
            .url = "https://example.com/sub?token=xxx",
            // .ua = "custom-ua/1.0",   // 本条订阅单独 UA
            // .enable = false,         // 临时禁用
        },
        .{ .name = "本地节点", .url = "/etc/nodes.txt" },
    },
}
```

`url` 支持 https、http、file:// 和本地文件路径。节点名格式：`订阅名@节点名`（分隔符可用 `--sep` 修改）。

### 匿名订阅

省略 `name` 即匿名订阅——行为和普通订阅完全一样，只是节点名不带前缀，适合临时节点：

```zig
.subscriptions = .{
    .{ .name = "airport", .url = "https://..." },  // 节点名：airport@xxx
    .{ .url = "/tmp/manual-nodes.txt" },           // 节点名：xxx（匿名）
}
```

### CLI 与 .zon 输入对照

| 输入 | CLI | .zon |
|---|---|---|
| 订阅（带名） | `--url name=<url>` | `.subscriptions` 写 name |
| 订阅（匿名） | `--url <url>` | `.subscriptions` 省略 name |
| 节点 URI | `--node <uri>` | `.nodes = .{ ... }` |
| 节点列表文件 | `--node-file <path>` | `.node_files = .{ ... }` |

### 完整配置字段

除 `--dry-run` 和 `-v` 外，所有 CLI 参数都能写进 `.zon`，优先级：CLI > .zon > 默认。全部配置进 .zon 后，一条命令即可部署：

```zig
.{
    .ua = "clash-verge/v2.2.3",
    .sep = "|",                        // 节点名分隔符
    .secret = "xxx",                   // API secret（默认自动生成）
    .timeout = 30,                     // 拉取超时（秒）
    .info_keywords = .{ "到期", "剩余流量" },  // 信息节点关键词
    .singbox_clash_api = true,         // sing-box 输出启用 clash_api
    .allow_lan = true,                 // clash 内置模板 allow-lan（clash 专用）
    .ipv6 = true,                      // clash 内置模板 ipv6 监听（clash 专用；ss-tproxy 支持 v6 透明代理时可开）
    .tproxy_port = 60080,              // tproxy 传入端口（clash tproxy-port / sing-box tproxy in；
                                       // 开启后 socks 传入保留，便于 debug/curl 测试；
                                       // 配合 .ipv6=true 实现 v4+v6 双栈 tproxy）
    .outputs = .{                      // 输出目标（默认 raw）
        .{ .fmt = .clash, .path = "/etc/clash/config.yaml" },
        .{ .fmt = .singbox, .path = "/etc/sing-box/config.json" },
    },
    .listen = "127.0.0.1",             // 以下为客户端监听参数
    .port = 1080,
    .mixed_port = 65500,
    .controller = "127.0.0.1:65501",
    .reload_cmd = "systemctl restart clash",
    .subscriptions = .{ ... },
}
```

```sh
subfetch -c config.zon    # 放进 cron / systemd timer 即可
```

注意：`.secret` 是敏感信息，含它的 .zon 不要提交到仓库。

## 信息节点过滤

机场订阅常夹带"通知节点"（如 `到期2026-12-21 剩余流量279.95G`），默认按关键词自动过滤。内置关键词：`到期` `剩余` `有效期` `套餐` `官网` + `expire` `traffic` `usage` `plan`（英文不区分大小写）。日志显示 `N info`，`-v` 可列出被过滤的节点。

自定义关键词（覆盖内置默认；空数组 = 不过滤）：

```zig
.{
    .info_keywords = .{ "到期", "剩余流量" },
}
```

CLI 等价写法：`--info-keyword 到期 --info-keyword 剩余流量`（`--info-keyword ""` 清空 = 不过滤）。

## 模板

clash / sing-box 输出支持自定义模板：模板是一份完整的配置文件，节点部分用**单行空列表**占位：

```yaml
# clash 模板（其余内容原样保留）
mixed-port: 7890
proxies: []          # 节点列表填充点（必填）
# proxy-groups / rules 不写即自动追加默认；写了就完全由你掌控
```

```json
// sing-box 模板
{
  "log": { "level": "debug" },
  "inbounds": [ ... ],
  "outbounds": [],   // 节点列表填充点
  "route": { "final": "PROXY" }
}
```

使用：`-o clash:模板路径=输出文件`。

规则：
- `proxies` / `"outbounds"` 填充点必须是单行空列表，否则报错
- `proxy-groups` / `rules`：模板中**缺失** → 自动追加默认；**写了**（无论内容）→ 完全保留你的内容
- 自定义组内节点列表用 `__NODES__` 锚点标记插入位置，subfetch 展开为真实节点名
- 不提供模板时使用内置默认模板

**注意**：`.listen`/`.port`/`.mixed_port`/`.allow_lan`/`.controller`/`.secret`/`.singbox_clash_api` 等输出配置参数**只在内置模板（不提供模板时）生效**；其中 `mixed_port`/`allow_lan`/`ipv6` 为 clash 专用（字段名与 clash 配置一致）。一旦使用自定义模板，模板就是最终配置——subfetch 只做填充点/锚点/默认组追加，不注入、不覆盖模板里的任何字段。

## 内置模板

不提供模板时使用内置模板——它是为 **ss-tproxy 配套场景**设计的最小可用配置，每条固定值都是架构要求而非随意选择：

- **DNS 分流归 chinadns-ng** → clash `dns: enable: false`、sing-box 无 dns 段
- **L4 分流归 ss-tproxy** → clash `rules: MATCH,PROXY`、sing-box `route.final: PROXY`（进来即全走代理）
- **不抢流量** → `tun: enable: false`
- **监听本地** → 默认 `listen: 127.0.0.1`（ss-tproxy 同机重定向）

### clash

```yaml
mixed-port: 65500          # ← .mixed_port
tproxy-port: 60080         # ← .tproxy_port（默认不启用）
allow-lan: false           # ← .allow_lan
ipv6: false                # ← .ipv6
mode: rule
log-level: info
external-controller: 127.0.0.1:65501   # ← .controller
secret: <自动UUID或配置>                 # ← .secret
profile: { store-selected: true }
dns: { enable: false }     # 固定：DNS 分流归 chinadns-ng
tun: { enable: false }     # 固定：不抢流量
proxies: []                # 填充点
# proxy-groups / rules 缺失 → 追加默认（PROXY[AUTO,DIRECT,节点] + MATCH,PROXY）
```

### sing-box

```json
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    { "type": "socks",  "tag": "socks-in",  "listen": "127.0.0.1", "listen_port": 1080 },
    { "type": "tproxy", "tag": "tproxy-in", "listen": "127.0.0.1", "listen_port": 60080 }
    // tproxy 可选（.tproxy_port）；socks 始终保留（debug/curl 测试）
    // .ipv6=true 时追加 tproxy-in-v6（::1），实现 v4+v6 双栈 tproxy
  ],
  "outbounds": [],
  "route": { "final": "PROXY" },
  "experimental": { "clash_api": { ... } }   // ← .singbox_clash_api
}
```

### 双栈 tproxy

`.tproxy_port` + `.ipv6` 组合：

| 格式 | 行为 |
|---|---|
| clash | `tproxy-port: 60080` + `ipv6: true` → 内部自动 v4+v6 监听（clash 无独立 listen 字段，`ipv6` 参数即双栈开关） |
| sing-box | 两个 tproxy inbound：`tproxy-in`（127.0.0.1）+ `tproxy-in-v6`（::1）；listen 映射 `127.0.0.1→::1`、`0.0.0.0→::` |

与 ipt2socks 对接场景对照：ipt2socks 自己监听 v4+v6 tproxy 端口对接 netfilter，客户端只需 socks；客户端直供 tproxy 时，`ipv6` 参数让两种方案的双栈语义一致。

## 输出格式

| 格式 | 说明 | 校验 |
|---|---|---|
| `clash` | clash / mihomo 聚合配置 | `mihomo -t` |
| `singbox` | sing-box 聚合配置 | `sing-box check` |
| `trojan` | trojan-go，每节点一个文件 | JSON 语法 |
| `hysteria` | hysteria 1.x，每节点一个文件 | JSON 语法 |
| `hysteria2` | hysteria 2.x，每节点一个文件 | YAML |
| `xray` | xray（vless），每节点一个文件 | `xray -test` |
| `ss` | shadowsocks，每节点一个文件 | JSON 语法 |
| `ssr` | shadowsocksr，每节点一个文件 | JSON 语法 |
| `raw` | 节点 JSON 列表（默认格式，脚本消费） | — |

原生格式每个节点一个文件，文件名即节点名（如 `香港1.json`）。校验程序找不到时自动跳过。sing-box 不支持 ssr / v2ray-plugin，这些节点会跳过并在日志提示。

## CLI 参数

```
-c, --config <path>      订阅列表配置（默认 ./subscriptions.zon）
-o, --output <fmt>[:<tmpl>][=<path>]  输出目标（可多次；默认 raw）
    --url [name=]<url>   命令行订阅（可多次；省略 name= 即匿名）
    --node <uri>         直接粘贴节点 URI（可多次）
    --node-file <path>   节点列表文件（每行一个 URI）
    --info-keyword <kw>  信息节点关键词（可多次；"" 清空 = 不过滤）
    --sep <str>          节点名前缀分隔符（默认 @）
    --dry-run            只校验不写文件
    --ua <str>           默认 User-Agent
    --timeout <sec>      拉取超时（秒）
    --listen <addr>      原生客户端监听地址
    --port <n>           原生客户端监听端口
    --mixed-port <n>     clash mixed-port
    --tproxy-port <n>    tproxy 传入端口（clash + sing-box 内置模板；socks 保留）
    --allow-lan          clash allow-lan（内置模板，默认关）
    --ipv6               clash ipv6 / sing-box v6 tproxy（内置模板，默认关）
    --controller <a:p>   clash / sing-box external-controller
    --secret <str>       API secret（默认自动生成 UUID）
    --singbox-clash-api  sing-box 输出启用 clash_api
    --no-verify          跳过校验
    --no-reload          安装后不重载
    --reload-cmd <cmd>   安装后执行自定义命令（覆盖自动重载）
-v, --verbose            详细输出
-h, --help               帮助
```

## 协议支持

| 协议 | 解析 | clash | sing-box | 原生 |
|---|---|---|---|---|
| vless（reality/tls/ws/grpc） | ✅ | ✅ | ✅ | ✅ xray |
| vmess | ✅ | ✅ | ✅ | — |
| trojan（ws/grpc） | ✅ | ✅ | ✅ | ✅ trojan-go |
| ss（obfs/v2ray-plugin/shadow-tls） | ✅ | ✅ | ✅ | ✅ sslocal |
| ssr | ✅ | ✅ | ❌ | ✅ shadowsocksr |
| hysteria 1.x | ✅ | ✅ | ✅ | ✅ hy1 |
| hysteria 2.x（obfs） | ✅ | ✅ | ✅ | ✅ hy2 |
| tuic | ✅ | ✅ | ✅ | — |

不支持的协议（如 anytls / wireguard）按行跳过并在日志提示。

## 构建

需要 Zig 0.15.2（版本锁定，其他版本会在编译期报错）。

```sh
zig build -Doptimize=ReleaseSafe        # x86_64-linux-musl 静态
zig build -Dtarget=aarch64-linux-musl   # 交叉编译（ARM 路由器等）
zig build test                          # 单元测试
```

产物在 `zig-out/bin/subfetch`。

## 平台

Linux 是目标平台（x86_64 / aarch64 / arm / riscv64 静态二进制）。macOS / Windows 保持可编译但不发布——本工具是 ss-tproxy 工具链的一环。

## 相关项目

- **subconverter**：在线转换 API 服务；subfetch 是本地 CLI，一条命令完成拉取 → 校验 → 安装 → 重载
- **Sub-Store**：Web 订阅管理器（QX/Loon/Surge 生态）；subfetch 面向服务器 / 路由器脚本化部署

## License

MIT
