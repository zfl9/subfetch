# subfetch

拉取订阅并生成 clash / sing-box / 原生代理客户端的配置，校验无误后安装并重载代理进程。

单文件、零依赖，适合放在服务器或路由器上定时执行，自动更新订阅。

## 特性

- 支持的协议：ss / ssr / vmess / vless / trojan / hysteria / hysteria2 / tuic
- 订阅格式：URI 列表、base64、clash YAML、v2rayN JSON、sing-box JSON
- 输出：clash / sing-box 聚合配置，原生客户端配置，raw 节点列表（JSON）
- 写配置前先校验，校验不过就不覆盖旧配置
- 安装后自动重载代理（可自定义重载命令）；订阅没更新时自动跳过安装与重载
- 任一订阅失败时保留上次成功配置并自动重试，配置不会因为一次失败就丢失

## 快速开始

先从 [Releases](https://github.com/zfl9/subfetch/releases) 下载对应架构的二进制（想自己构建见文末）。

```sh
# 1. 复制示例配置并编辑
cp config.example.zon config.zon
vim config.zon

# 2. 预览：输出到终端，不写文件
subfetch -c config.zon -o clash=- --dry-run

# 3. 安装并重载
subfetch -c config.zon -o clash=/etc/clash/config.yaml \
    --reload-cmd "systemctl restart clash"
```

也可以不用配置文件，直接用命令行：`subfetch --url 订阅URL` 或 `subfetch --node 节点URI`。

## 配置

配置文件是 .zon 格式（类似 JSON 的文本，支持注释）。下面是最小可用配置：

```zig
.{
    .ua = "clash-verge/v2.2.3",        // 默认 User-Agent
    .subscriptions = .{
        .{
            .name = "xx机场",            // 订阅名，作为节点名的前缀
            .url = "https://example.com/sub?token=xxx",
            // .ua = "custom-ua/1.0",   // 本条订阅单独的 User-Agent
        },
        .{ .url = "/etc/nodes.txt" },   // 不需要订阅名就省略 name
    },
}
```

`url` 支持 https / http / `file://` 或本地路径。节点名格式为 `订阅名@节点名`，分隔符可用 `--sep` 修改。

CLI 与 .zon 一一对应：

| 输入 | CLI | .zon |
|---|---|---|
| 订阅（带名） | `--url name=<url>` | `.subscriptions` 里写 name |
| 订阅（匿名） | `--url <url>` | `.subscriptions` 里省略 name |
| 节点 URI | `--node <uri>` | `.nodes = .{ ... }` |
| 节点列表文件 | `--node-file <path>` | `.node_files = .{ ... }` |

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
    .outputs = .{                          // 输出目标，默认 raw
        .{
            .fmt = .clash,
            .path = "/etc/clash/config.yaml",
            .reload_cmd = "systemctl restart clash",
            .verify = false,               // 可选：跳过该校验（默认开）
            .reload = false,               // 可选：跳过该重载（默认开）
        },
        .{ .fmt = .singbox, .path = "/etc/sing-box/config.json" },
    },
    .subscriptions = .{ ... },
}
```

之后每天只需一条命令：`subfetch -c config.zon`。

## 通知节点过滤

机场订阅常夹带通知节点（如 `到期2026-12-21 剩余流量279.95G`）。默认按关键词过滤：`到期` `剩余` `有效期` `套餐` `官网` + `expire` `traffic` `usage` `plan`（英文不区分大小写）。日志会显示过滤数量，`-v` 可列出被过滤的节点。

自定义关键词会覆盖默认（空数组 = 不过滤）：

```zig
.{
    .info_keywords = .{ "到期", "剩余流量" },
}
```

CLI 等价写法：`--info-keyword 到期 --info-keyword 剩余流量`；`--info-keyword ""` 清空。

## 输出格式

| 格式 | 说明 | 安装前校验 |
|---|---|---|
| `clash` | clash / mihomo 聚合配置 | `mihomo -t` |
| `singbox` | sing-box 聚合配置 | `sing-box check` |
| `xray` | xray 配置，每节点一个文件 | `xray -test` |
| `trojan` `hysteria` `hysteria2` `ss` `ssr` | 原生客户端配置，每节点一个文件 | 语法检查 |
| `raw` | 节点列表（JSON，默认格式） | — |

- `-o` 语法：`-o <fmt>[:模板路径]=<输出路径>`，可多次
- 路径写 `-` 则输出到终端（配合 `--dry-run` 预览）
- 原生格式文件名即节点名；没装校验程序时退化为语法检查；sing-box 不支持的节点（ssr、v2ray-plugin）自动跳过并在日志提示

## 模板

clash / sing-box 输出支持自定义模板：一份完整的配置文件，把节点列表位置留成空：

```yaml
proxies: []    # clash
```

```json
"outbounds": []    // sing-box
```

- 模板里没写 `proxy-groups` / `rules` 会自动补默认，写了就完全保留
- 组里的节点列表用 `__NODES__` 标记插入位置
- 模板即最终配置：subfetch 只填充节点列表，不改动任何其他字段

## 内置模板

不提供模板时使用内置模板，按 ss-tproxy 场景设计：DNS 分流交给 chinadns-ng、L4 分流交给 ss-tproxy（流量全部进代理）、不启用 tun、监听 127.0.0.1。配置里的 `listen` / `port` / `mixed_port` / `tproxy_port` / `allow_lan` / `tproxy_ipv6` / `log_level` / `controller` / `secret` / `singbox_clash_api` 就是内置模板的参数，自定义模板下这些字段不生效。

## CLI 参数

```
Config:
-c, --config <path>      配置 zon（默认 ./config.zon）

Input:
    --url <[name=]url>   订阅 URL（可多次；省略 [name=] 即匿名）
    --node <uri>         直接粘贴节点 URI（可多次）
    --node-file <path>   节点列表文件（每行一个 URI）

Output:
-o, --output <fmt>[:<tmpl>][=<path>]
                          输出目标（可多次；默认 raw）
                          fmt: clash|singbox|trojan|hysteria|hysteria2|xray|ss|ssr|raw
                          tmpl: 自定义模板文件（clash/singbox）
                          path: 输出文件或目录；'-' = 终端

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

不支持的协议（如 anytls / wireguard）按行跳过并在日志提示。

## 退出码

| 退出码 | 含义 |
|---|---|
| 0 | 成功（含 dry-run 通过） |
| 1 | 运行出错（文件读写、安装、备份等） |
| 2 | 命令行用法错误（未知参数、--url 为空、-o 缺少输出路径） |
| 3 | 配置或数据错误（配置文件缺失或格式错误、订阅名重复、模板错误、无可用节点、校验失败） |
| 4 | 订阅源失败：任一订阅或节点文件拉取/解析失败（保留上次成功配置，下次运行自动重试） |

## 构建

需要 Zig 0.15.2（其他版本直接编译报错）。

```sh
zig build -Doptimize=ReleaseSmall                     # x86_64-linux-musl 静态二进制
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall   # 交叉编译
zig build test                                          # 单元测试
zig build smoke                                        # 9 格式冒烟（dry-run）
zig build integration                                 # 集成测试（安装/退出码/并发锁）
                                                      # -Dintegration_filter=lock 只跑单套件
```

产物在 `zig-out/bin/subfetch`。

## 平台

Linux 是目标平台（x86_64 / aarch64 / arm / riscv64 等）。macOS / Windows 能编译但不发布——本工具是 ss-tproxy 工具链的一环。

## 相关项目

- **subconverter**：在线转换 API 服务；subfetch 是本地 CLI，一条命令完成拉取 → 校验 → 安装 → 重载
- **Sub-Store**：Web 订阅管理器（QX/Loon/Surge 生态）；subfetch 面向服务器 / 路由器脚本化部署

## License

MIT
