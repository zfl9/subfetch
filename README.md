# subfetch

拉取订阅并生成 clash / sing-box / 原生代理客户端的配置，校验无误且订阅变更时才重启代理进程。

静态链接的单文件，适合放在家用服务器、路由器上定时执行 (crontab / systemd timer)，自动更新订阅。

## 特性

- 支持的协议：ss / ssr / vmess / vless / trojan / hysteria / hysteria2 / tuic
- 订阅格式：URI 列表、base64、clash YAML、v2rayN JSON、sing-box JSON
- 输出：clash / sing-box 聚合配置，原生客户端配置，raw 节点列表（JSON）
- 写配置前先校验（优先使用真实客户端进行校验），校验失败将保留原有配置
- 安装后自动重载代理（可自定义重载命令）；订阅没更新时自动跳过安装与重载

## 快速开始

从 [Releases](https://github.com/zfl9/subfetch/releases) 下载对应架构的二进制。

```sh
# 1. 复制示例配置并编辑
cp config.example.zon config.zon
vim config.zon

# 2. 预演：渲染并验证配置，不写文件
subfetch -c config.zon -o clash=/etc/clash/config.yaml --dry-run

# 3. 安装并重载
subfetch -c config.zon -o clash=/etc/clash/config.yaml \
    --reload-cmd "systemctl restart clash"
```

也可以不用配置文件，直接用命令行：`subfetch --url 订阅URL` 或 `subfetch --node 节点URI`。

## 配置

配置文件是 .zon 格式（类似 JSON 的文本，支持注释）。下面是最小可用配置：

```zig
.{
    .subscriptions = .{
        .{
            .name = "xx机场", // 订阅名，作为节点名的前缀
            .url = "https://example.com/sub?token=xxx",
        },
        .{
            // 不需要订阅名就省略 name
            .url = "https://example.com/anon",
        },
    },
}
```

CLI 与 .zon 一一对应：

| 输入 | CLI | .zon |
|---|---|---|
| 订阅（带名） | `--url name=<url>` | `.subscriptions` 里写 name |
| 订阅（匿名） | `--url <url>` | `.subscriptions` 里省略 name |
| 节点 URI | `--node <uri>` | `.nodes = .{ ... }` |
| 节点列表文件 | `--url <本地路径>` | `.subscriptions` 里写本地路径 |

所有 CLI 参数都能写进 .zon，优先级 CLI > .zon > 默认值：

```zig
.{
    .ua = "clash-verge/v2.2.3",
    .sep = "@",                            // 订阅名和节点名之间的分隔符
    .secret = "xxx",                       // API secret（默认自动生成并持久化）
    .info_keywords = .{ "到期", "剩余流量" }, // 通知节点关键词
    .listen = "127.0.0.1",                 // 客户端监听地址
    .port = 1080,                          // 客户端监听端口
    .mixed_port = 65500,                   // clash mixed-port（clash 专用）
    .allow_lan = true,                     // clash allow-lan（clash 专用）
    .tproxy_port = 60080,                  // tproxy 端口（clash + sing-box）
    .tproxy_ipv6 = true,                   // v6 tproxy 双栈
    .log_level = .warn,                    // 客户端日志级别 debug|info|warn|err
    .controller = "127.0.0.1:65501",       // clash external-controller / sing-box clash_api（需 .singbox_clash_api）
    .singbox_clash_api = true,             // sing-box 输出启用 clash_api
    .reload_cmd = "systemctl restart clash", // 所有输出的默认重载命令
    .outputs = .{                          // 输出目标（必须至少一个）
        .{
            .fmt = .clash,
            .path = "/etc/clash/config.yaml",
            .reload_cmd = "systemctl restart clash",
        },
        .{ .fmt = .singbox, .path = "/etc/sing-box/config.json" },
    },
    .subscriptions = .{ ... },
}
```

crontab / systemd timer 中只需执行：`subfetch -c /path/to/config.zon`。

## 输出格式

| 格式 | 说明 | 安装前校验 |
|---|---|---|
| `clash` | clash / mihomo 聚合配置 | `mihomo -t` |
| `singbox` | sing-box 聚合配置 | `sing-box check` |
| `xray` | xray 配置，每节点一个文件 | `xray -test` |
| `trojan` `hysteria` `hysteria2` `ss` `ssr` | 原生客户端配置，每节点一个文件 | 语法检查 |
| `raw` | 节点列表（JSON） | — |

- `-o` 语法：`-o <fmt>[:模板路径]=<输出路径>`，可多次
- 不指定 `-o` 且配置里没有 `.outputs`，会报错；`--dry-run` 预演时不写文件

## 模板

clash / sing-box 输出支持自定义模板：一份完整的配置文件，把节点列表位置留成空：

```yaml
# 对于 clash
proxies: []
```

```json
// 对于 sing-box
"outbounds": []
```

- 模板里没写 `proxy-groups` / `rules` 会自动补默认，写了就完全保留
- proxy-groups 的节点列表中可用 `__NODES__` 特殊节点名来标记插入位置
- 模板即最终配置：subfetch 只填充 & 展开节点列表，不改动任何其他字段

## 内置模板

不提供模板时将使用内置模板，内置模板是按 ss-tproxy 使用场景设计的：DNS 分流交给 chinadns-ng、L4 分流交给 ss-tproxy（流量全部进代理）、只监听 127.0.0.1（socks5 / tproxy）。

这些配置属于内置模板的控制参数（自定义模板时将完全忽略）：`listen` / `port` / `mixed_port` / `tproxy_port` / `allow_lan` / `tproxy_ipv6` / `log_level` / `controller` / `secret` / `singbox_clash_api`。

## CLI 参数

```
Config:
-c, --config <path>      配置 zon（默认 ./config.zon）

Input:
    --url <[name=]url>   订阅 URL（可多次；省略 [name=] 即匿名）；本地文件路径或 file:// 也会读取
    --node <uri>         直接粘贴节点 URI（可多次）

Output:
-o, --output <fmt>[:<tmpl>]=<path>
                          输出目标（可多次；不指定则报错，除非配置了 .outputs）
                          fmt: clash|singbox|trojan|hysteria|hysteria2|xray|ss|ssr|raw
                          tmpl: 自定义模板文件（clash/singbox）
                          path: 输出文件或目录（真实运行必填）

Client config（仅内置模板生效）:
    --listen <addr>      socks5 监听地址（默认 127.0.0.1）
    --port <n>           socks5 监听端口（默认 1080）
    --mixed-port <n>     clash mixed-port（默认 65500）
    --controller <a:p>   API 地址（clash/sing-box；默认 127.0.0.1:65501）
    --secret <str>       API secret（默认自动生成并持久化）
    --singbox-clash-api  sing-box 输出启用 clash_api
    --allow-lan          clash allow-lan
    --tproxy-port <n>    tproxy 端口（clash + sing-box）
    --tproxy-ipv6        v6 tproxy 双栈（clash + sing-box）
    --log-level <level>  客户端日志级别 debug|info|warn|err（默认 info）

Deploy:
    --no-verify          跳过安装前校验
    --no-reload          安装后不重载
    --reload-cmd <cmd>   安装后执行自定义命令（sh -c '<cmd>'）

Misc:
    --dry-run            只校验不写文件
    --ua <str>           发送给订阅服务器的 User-Agent
    --info-keyword <kw>  通知节点关键词（可多次；"" = 不过滤）
    --sep <str>          订阅名/节点名分隔符（默认 @）
    --reset-state        删除已持久化的 API secret（下次运行重新生成）
  -v, --verbose          详细输出（节点列表）
  -h, --help             帮助
  -V, --version          输出版本号
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
| hysteria 2.x | ✅ | ✅ | ✅ | ✅ hy2 |
| tuic | ✅ | ✅ | ✅ | — |

> 不支持的协议（如 anytls / wireguard）自动跳过并在日志中提示。

## 构建

> 工具链锁定为 Zig 0.15.2 版本。

```sh
# 本机 musl 静态链接
zig build -Doptimize=ReleaseSmall

# 交叉编译：aarch64 (arm64)
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall
```

产物在 `zig-out/bin/subfetch`。

## 平台

Linux 是目标平台（x86_64 / aarch64 / arm / riscv64 等）。macOS / Windows 能编译但不发布。

## 相关项目

- **subconverter**：在线转换 API 服务；subfetch 是本地 CLI，一条命令完成拉取 → 校验 → 安装 → 重载
- **Sub-Store**：Web 订阅管理器（QX/Loon/Surge 生态）；subfetch 面向服务器 / 路由器脚本化部署

## License

MIT
