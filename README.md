# subfetch

拉取订阅 & 生成 clash / sing-box / 原生代理客户端的配置，校验配置无误后再重载代理进程。

静态链接的单二进制、零运行时依赖；适合在家用服务器、家用路由器上定时执行，自动更新订阅。

## 特性

- 支持的代理协议：ss / ssr / vmess / vless / trojan / hysteria / hysteria2 / tuic
- 支持的订阅链接格式：URI 列表、base64、clash YAML、v2rayN JSON、sing-box JSON
- 支持的配置输出格式：clash / sing-box 聚合，ss / ssr / trojan / xray / hysteria / hysteria2 原生，raw 节点列表
- 安装配置文件前校验：`mihomo -t` / `sing-box check` / `xray -test`，校验成功后才会覆盖旧配置；校验进程 30s 超时保护（挂起自动终止，不会卡住定时任务）
- 安装配置文件后重载：clash controller API 优先，失败自动回退 systemctl，可自定义重载命令
- 配置无变化时跳过安装与重载：生成的配置与现有配置字节一致（订阅未更新）时，不写文件、不触发 reload，避免无意义的 systemctl restart
- 订阅内部节点按名称稳定排序（所有输出格式生效，含 raw）：上游节点顺序变化不会改变配置内容，进一步避免误触发 reload；订阅之间的顺序与用户直接提供的节点（--node / --node-file）保持原样
- 并发运行保护：flock 互斥锁（state 目录），cron 重叠触发时等待前一次完成后再执行，避免临时文件与安装竞争；进程异常退出时内核自动释放锁
- 订阅源失败保护：任一订阅或节点文件 fetch/parse 失败 → 跳过本次安装（保留上次成功配置，失败订阅的节点不会从运行配置中消失），退出码 4 通知 cron；瞬时网络错误自动重试 1 次
- 明确的退出码语义（见下表），cron / 脚本可区分成功、用法错误、配置错误与订阅源失败

## 退出码

| 码 | 含义 |
|---|---|
| 0 | 成功（含 dry-run 通过） |
| 1 | 运行期失败（IO、安装、备份、state 操作等） |
| 2 | 命令行用法错误（未知参数、--url 为空、-o 缺少输出路径） |
| 3 | 配置/数据错误（config 缺失或解析失败、重复名称、模板失败、无可用节点、校验失败） |
| 4 | 订阅源失败：任一订阅或节点文件 fetch/parse 失败即返回 4（跳过本次安装、保留上次成功配置，cron 可据此感知，下个周期自动重试） |

## 快速开始

```sh
# 1. 复制配置模板，并编辑
cp config.example.zon config.zon
vim config.zon

# 2. 预览（输出到 stdout，不写文件）
subfetch -c config.zon -o clash=- --dry-run

# 3. 安装并重载
subfetch -c config.zon -o clash=/etc/clash/config.yaml \
    --reload-cmd "systemctl restart clash"
```

也可以不用配置文件，直接命令行输入：`--url 订阅链接` / `--node 节点uri`。

## 配置

```zig
.{
    .ua = "clash-verge/v2.2.3",           // 默认 User-Agent
    .subscriptions = .{
        .{
            .name = "xx机场",              // 给订阅命个名，作为节点名的前缀
            .url = "https://example.com/sub?token=xxx",
            // .ua = "custom-ua/1.0",      // 本条订阅的单独 UA
        },
        .{ .url = "/etc/nodes.txt" },      // 若不需要订阅名，直接省略 name 字段
    },
}
```

`url` 支持 https / http / `file://` / 本地路径。节点名的输出格式为 `订阅名@节点名`，分隔符可用 `--sep` 修改。

CLI 与 .zon 输入一一对应：

| 输入 | CLI | .zon |
|---|---|---|
| 订阅（带名） | `--url name=<url>` | `.subscriptions` 写 name |
| 订阅（匿名） | `--url <url>` | `.subscriptions` 省略 name |
| 节点 URI | `--node <uri>` | `.nodes = .{ ... }` |
| 节点列表文件 | `--node-file <path>` | `.node_files = .{ ... }` |

基本所有的 CLI 参数都能写进 .zon，优先级 CLI > .zon > 程序默认：

```zig
.{
    .ua = "clash-verge/v2.2.3",
    .sep = "@",                        // 订阅名和节点名之间的分隔符
    .secret = "xxx",                   // API secret（默认自动生成并持久化到 ~/.local/state/subfetch/secret，跨运行稳定）
    .timeout = 5,                      // 单订阅拉取超时（秒，默认 5）
    .info_keywords = .{ "到期", "剩余流量" },  // 信息节点关键词
    .listen = "127.0.0.1",             // 客户端监听地址
    .port = 1080,                      // 客户端监听端口
    .mixed_port = 65500,               // clash mixed-port（clash 专用）
    .allow_lan = true,                 // clash allow-lan（clash 专用）
    .tproxy_port = 60080,              // tproxy 端口（clash + sing-box）
    .tproxy_ipv6 = true,               // v6 tproxy 双栈（clash ipv6 / sing-box tproxy-in-v6）
    .log_level = "warning",            // 客户端日志级别 debug|info|warning|error
    .controller = "127.0.0.1:65501",   // clash external-controller / sing-box clash_api（需 .singbox_clash_api）
    .singbox_clash_api = true,         // sing-box 输出启用 clash_api
    .reload_cmd = "systemctl restart clash",   // 所有输出的默认重载命令
    .outputs = .{                               // 输出目标，默认 raw
        .{ .fmt = .clash, .path = "/etc/clash/config.yaml", .reload_cmd = "systemctl restart clash" },
        .{ .fmt = .singbox, .path = "/etc/sing-box/config.json" },
    },
    .subscriptions = .{ ... },
}
```

全部配置进 .zon 后，一条命令即可完成：订阅更新 & 代理进程重载。

```sh
subfetch -c config.zon
```

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

- `-o` 语法：`-o <fmt>[:模板路径]=<输出路径>`，可多次
- 路径写 `-` 则输出到 stdout（配合 `--dry-run` 预览）
- 原生格式文件名即节点名；校验程序不在 PATH 时自动跳过；sing-box 不支持的节点（ssr、v2ray-plugin）自动跳过并在日志提示

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
    --timeout <sec>      单订阅拉取超时（秒，默认 5）
    --listen <addr>      客户端监听地址（默认 127.0.0.1）
    --port <n>           客户端监听端口（默认 1080，socks5）
    --mixed-port <n>     clash mixed-port（默认 65500）
    --allow-lan          clash allow-lan（默认关）
    --tproxy-port <n>    tproxy 端口（默认不启用）
    --tproxy-ipv6        v6 tproxy 双栈（默认关）
    --log-level <lvl>    客户端日志级别 debug|info|warning|error（默认 info）
    --controller <a:p>   clash external-controller / sing-box clash_api
                         （sing-box 需配合 --singbox-clash-api）
    --secret <str>       API secret（默认自动生成并持久化，跨运行稳定）
    --singbox-clash-api  sing-box 输出启用 clash_api
    --no-verify          跳过校验
    --no-reload          安装后不重载
    --reload-cmd <cmd>   安装后执行自定义命令（优先于 .zon 配置）
    --reset-state        删除持久化的 API secret（state 目录，下次运行自动生成新的；lock 文件保留）
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
