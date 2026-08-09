# subfetch

拉取订阅、生成 clash / sing-box / 原生客户端配置，安装前用真实客户端校验，安装后自动重载。单二进制、零运行时依赖，适合服务器和路由器上用 cron 定时运行。

## 特性

- 解析 8 种协议：ss / ssr / vmess / vless / trojan / hysteria / hysteria2 / tuic
- 自动识别订阅格式：URI 列表、base64、clash YAML、v2rayN JSON、sing-box JSON
- 输出 9 种格式：clash / sing-box 聚合配置，ss / ssr / trojan / xray / hysteria / hysteria2 原生配置，raw 节点列表
- 安装前校验（`mihomo -t` / `sing-box check` / `xray -test`），失败不覆盖旧配置
- 安装后重载（clash API 优先，回退 systemctl，可自定义命令）
- 自动过滤机场通知节点（到期 / 流量提示），关键词可配置
- 配置用 .zon 类型安全格式，字段拼错直接报错

## 快速开始

```sh
# 1. 复制模板并编辑（覆盖全部字段，注释里写了每个字段的用途）
cp config.example.zon config.zon
vim config.zon

# 2. 预览（输出到 stdout，不写文件）
subfetch -c config.zon -o clash=- --dry-run

# 3. 安装并重载
subfetch -c config.zon -o clash=/etc/clash/config.yaml \
    --reload-cmd "systemctl restart clash"
```

不建配置文件也能用：`--url` / `--node` 直接在命令行输入。默认运行会尝试加载当前目录的 `config.zon`（存在即生效）；用 `-c` 指定后只读该文件，文件缺失会报错。

## 配置

```zig
.{
    .ua = "clash-verge/v2.2.3",           // 默认 User-Agent
    .subscriptions = .{
        .{
            .name = "香港机场",             // 节点名前缀，省略即匿名
            .url = "https://example.com/sub?token=xxx",
            // .ua = "custom-ua/1.0",      // 本条订阅单独 UA
            // .enable = false,            // 临时禁用
        },
        .{ .url = "/etc/nodes.txt" },      // 本地节点列表，匿名
    },
}
```

`url` 支持 https / http / file:// / 本地路径。节点名格式为 `订阅名@节点名`，分隔符可用 `--sep` 修改。省略 `name` 即匿名订阅，节点名不带前缀。

CLI 与 .zon 输入一一对应：

| 输入 | CLI | .zon |
|---|---|---|
| 订阅（带名） | `--url name=<url>` | `.subscriptions` 写 name |
| 订阅（匿名） | `--url <url>` | `.subscriptions` 省略 name |
| 节点 URI | `--node <uri>` | `.nodes = .{ ... }` |
| 节点列表文件 | `--node-file <path>` | `.node_files = .{ ... }` |

除 `--dry-run`、`-v` 外，所有 CLI 参数都能写进 .zon，优先级 CLI > .zon > 默认：

```zig
.{
    .ua = "clash-verge/v2.2.3",
    .sep = "|",                        // 节点名分隔符
    .secret = "xxx",                   // API secret（默认自动生成）
    .timeout = 15,                     // 单订阅拉取超时（秒，默认 15）
    .info_keywords = .{ "到期", "剩余流量" },  // 信息节点关键词
    .listen = "127.0.0.1",             // 客户端监听地址
    .port = 1080,                      // socks 端口
    .mixed_port = 65500,               // clash mixed-port（clash 专用）
    .allow_lan = true,                 // clash allow-lan（clash 专用）
    .tproxy_port = 60080,              // tproxy 端口（clash + sing-box）
    .tproxy_ipv6 = true,               // v6 tproxy 双栈（clash ipv6 / sing-box tproxy-in-v6）
    .log_level = "warning",            // 客户端日志级别 debug|info|warning|error
    .controller = "127.0.0.1:65501",   // clash external-controller / sing-box clash_api
    .singbox_clash_api = true,         // sing-box 输出启用 clash_api
    .reload_cmd = "systemctl restart clash",
    .outputs = .{                      // 输出目标，默认 raw
        .{ .fmt = .clash, .path = "/etc/clash/config.yaml" },
        .{ .fmt = .singbox, .path = "/etc/sing-box/config.json" },
    },
    .subscriptions = .{ ... },
}
```

全部配置进 .zon 后，一条命令即可部署，cron / systemd timer 同样适用：

```sh
subfetch -c config.zon
```

`.secret` 是敏感信息，含它的 .zon 不要提交到仓库。

## 信息节点过滤

机场订阅常夹带通知节点（如 `到期2026-12-21 剩余流量279.95G`），默认按关键词过滤：`到期` `剩余` `有效期` `套餐` `官网` + `expire` `traffic` `usage` `plan`（英文不区分大小写）。日志显示 `N info`，`-v` 列出被过滤的节点。

自定义关键词覆盖默认（空数组 = 不过滤）：

```zig
.{
    .info_keywords = .{ "到期", "剩余流量" },
}
```

CLI 等价写法：`--info-keyword 到期 --info-keyword 剩余流量`，`--info-keyword ""` 清空。

## 输出格式

| 格式 | 说明 | 安装前校验 |
|---|---|---|
| `clash` | clash / mihomo 聚合配置 | `mihomo -t` |
| `singbox` | sing-box 聚合配置 | `sing-box check` |
| `xray` | xray 配置，每节点一文件 | `xray -test` |
| `trojan` `hysteria` `hysteria2` `ss` `ssr` | 原生客户端配置，每节点一文件 | JSON / YAML 语法检查 |
| `raw` | 节点 JSON 列表（默认格式，脚本消费） | — |

`-o` 语法：`-o <fmt>[:模板路径]=<输出路径>`，可多次；路径写 `-` 则输出到 stdout（配合 `--dry-run` 预览）。原生格式文件名即节点名。校验程序不在 PATH 时自动跳过；sing-box 不支持的节点（ssr、v2ray-plugin）自动跳过并在日志提示。

## 模板

clash / sing-box 输出支持自定义模板：一份完整的配置文件，节点列表位置用单行空列表占位：

```yaml
proxies: []    # clash
```

```json
"outbounds": []    // sing-box
```

- `proxy-groups` / `rules`：模板里缺失 → 自动追加默认；写了 → 完全保留
- 自定义组内节点列表用 `__NODES__` 标记插入位置
- 模板即最终配置：subfetch 只做填充，不注入、不覆盖任何字段

## 内置模板

不提供模板时使用内置模板，按 ss-tproxy 场景设计：DNS 分流归 chinadns-ng、L4 分流归 ss-tproxy（全部流量进代理）、不启用 tun、监听 127.0.0.1。配置字段中的 `listen` / `port` / `mixed_port` / `tproxy_port` / `allow_lan` / `tproxy_ipv6` / `log_level` / `controller` / `secret` / `singbox_clash_api` 即对应内置模板的参数，自定义模板下这些字段不生效。

## CLI 参数

```
-c, --config <path>      配置 zon（默认 ./config.zon）
-o, --output <fmt>[:<tmpl>][=<path>]  输出目标（可多次；默认 raw）
    --url [name=]<url>   命令行订阅（可多次；省略 name= 即匿名）
    --node <uri>         直接粘贴节点 URI（可多次）
    --node-file <path>   节点列表文件（每行一个 URI）
    --info-keyword <kw>  信息节点关键词（可多次；"" 清空 = 不过滤）
    --sep <str>          节点名前缀分隔符（默认 @）
    --dry-run            只校验不写文件
    --ua <str>           默认 User-Agent
    --timeout <sec>      单订阅拉取超时（秒，默认 15）
    --listen <addr>      客户端监听地址（默认 127.0.0.1）
    --port <n>           socks5 端口（默认 1080）
    --mixed-port <n>     clash mixed-port（默认 65500）
    --allow-lan          clash allow-lan（默认关）
    --tproxy-port <n>    tproxy 端口（默认不启用）
    --tproxy-ipv6        v6 tproxy 双栈（默认关）
    --log-level <lvl>    客户端日志级别 debug|info|warning|error（默认 info）
    --controller <a:p>   clash external-controller / sing-box clash_api
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
| hysteria 2.x | ✅ | ✅ | ✅ | ✅ hy2 |
| tuic | ✅ | ✅ | ✅ | — |

不支持的协议（如 anytls / wireguard）按行跳过并在日志提示。

## 构建

需要 Zig 0.15.2（版本锁定，其他版本编译期直接报错）。

```sh
zig build -Doptimize=ReleaseSmall                     # x86_64-linux-musl 静态二进制
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall   # 交叉编译
zig build test                                        # 单元测试
```

产物在 `zig-out/bin/subfetch`。

## 平台

Linux 是目标平台（x86_64 / aarch64 / arm / riscv64 等静态发布）。macOS / Windows 保持可编译但不发布——本工具是 ss-tproxy 工具链的一环。

## 相关项目

- **subconverter**：在线转换 API 服务；subfetch 是本地 CLI，一条命令完成拉取 → 校验 → 安装 → 重载
- **Sub-Store**：Web 订阅管理器（QX/Loon/Surge 生态）；subfetch 面向服务器 / 路由器脚本化部署

## License

MIT
