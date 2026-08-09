# subfetch

订阅拉取 & 多格式配置生成工具：从各种订阅链接抓取节点，转换并输出为 clash / sing-box / 各原生客户端的配置文件，带**真实客户端校验、原子安装与热重载**闭环。

纯 CLI、单二进制、零运行时依赖（musl 静态链接），适合服务器 / 路由器上 cron 或脚本化部署。

## 特性

- **8 协议解析**：ss / ssr / vmess / vless(+reality) / trojan / hysteria / hysteria2 / tuic
- **5 种订阅格式自动探测**：URI 行列表、base64（递归）、clash YAML、clash JSON、v2rayN JSON；HTML 页面自动拒绝
- **9 种输出格式**：clash(mihomo) / sing-box 聚合输出 + ss / ssr / trojan / xray(vless) / hysteria / hysteria2 原生输出 + raw（JSON 节点列表）
- **校验闭环**：安装前用真实客户端校验——`mihomo -t`、`sing-box check`、`xray -test`，找不到校验程序自动跳过
- **原子安装**：写 `.new` → 校验 → 备份 `.bak` → rename 替换，校验失败不动旧配置
- **热重载**：clash / sing-box 自动走 API 重载（失败回退 systemctl）；任意格式可用 `--reload-cmd` 指定自定义重载命令（acme.sh 风格）
- **配置即代码**：`.zon` 类型安全配置，字段拼错解析期即报错；`--dry-run` 全流程预览
- **单二进制**：Zig 实现，musl 静态链接，交叉编译一行命令（含 RPi）

## 构建

需要 [Zig 0.15.2](https://ziglang.org/download/)，**版本精确锁定**（Zig 各版本间 API 破坏性变更频繁，其他版本会在编译期直接报错提示）。

```sh
zig build -Doptimize=ReleaseSafe        # 默认 x86_64-linux-musl 静态
zig build -Dtarget=aarch64-linux-musl   # 交叉编译（RPi / ARM 路由器）
zig build test                          # 单元测试（103 个）
```

产物在 `zig-out/bin/subfetch`。

## 快速开始

```sh
# 1. 复制模板并编辑订阅列表（名称/URL/UA/开关）
cp subscriptions.example.zon subscriptions.zon
vim subscriptions.zon

# 2. 预览（dry-run：校验但不写文件；想看内容用 -o clash=- 输出到 stdout）
subfetch --config subscriptions.zon -o clash --dry-run

# 3. 安装并重载（正式运行必须给输出路径）
subfetch --config subscriptions.zon -o clash=/etc/clash/config.yaml \
    --reload-cmd "systemctl restart clash"

# 多目标：clash 到 stdout + singbox 落盘（一次运行）
subfetch --config subscriptions.zon -o clash=- -o singbox=/etc/sing-box/config.json
```

## 配置（subscriptions.example.zon → subscriptions.zon）

```zig
.{
    .default_ua = "clash-verge/v2.2.3",          // 默认 User-Agent（可选）
    .subscriptions = .{
        .{
            .name = "香港机场",                    // 订阅名：节点名前缀（支持中文，≤32）
            .url = "https://example.com/sub?token=xxx",
            // .ua = "custom-ua/1.0",              // 覆盖 default_ua（可选）
            // .enable = false,                    // 临时禁用（可选，默认 true）
        },
        .{ .name = "美西节点", .url = "/etc/sub.txt" },
    },
}
```

`url` 支持 `https://`、`http://`、`file://`、本地文件路径。节点名格式：`订阅名@节点名`（分隔符可用 `--sep` 修改）。

### 匿名订阅

`name` **省略**即匿名订阅——处理管线与普通订阅完全一致（格式探测/信息节点过滤照常），唯一区别是节点名**不带 `订阅名@` 前缀**，日志标签固定为 `[anonymous]`（不泄露 url，url 可能含 token）。**显式 `name = ""` 会被拒绝**——要匿名就省略字段：

```zig
.{
    .subscriptions = .{
        .{ .url = "/tmp/manual-nodes.txt" },   // 匿名：节点名无前缀
        .{ .name = "airport", .url = "https://..." },  // 具名：airport@节点名
    },
}
```

### 输入源矩阵（CLI 与 .zon 对称）

| 输入形态 | CLI | .zon |
|---|---|---|
| 具名订阅（sniff + 信息过滤 + `name@` 前缀） | `--url name=<url>` | `.subscriptions` 带 name |
| 匿名订阅（同上，无前缀） | `--url <url>` | `.subscriptions` 省略 name |
| 节点直连（不探测、不过滤、无前缀） | `--node <uri>` | `.nodes = .{ ... }` |
| 节点文件（同上，文件批量 + `#` 注释） | `--node-file <path>` | `.node_files = .{ ... }` |

处理顺序：节点（CLI 先于 .zon）→ 节点文件（CLI 先于 .zon）→ 订阅（CLI 先于 .zon）。订阅名跨 CLI/.zon 不允许重复（匿名订阅可多个）。

### 配置化运行参数

`.zon` 还可配置 `sep`（节点名分隔符）、`secret`（clash/sing-box API secret）、`info_node_keywords`（信息节点关键词），优先级 **CLI > .zon > 代码默认**：

```zig
.{
    .sep = "|",            // 覆盖默认 "@"；--sep 可再覆盖
    .secret = "xxx",       // 覆盖自动生成 UUID；--secret 可再覆盖
    .info_node_keywords = .{ "到期", "剩余流量" },  // 覆盖内置默认；--info-keyword 可再覆盖
    ...
}
```

CLI 侧：`--info-keyword <kw>` 可重复（提供则覆盖 .zon/默认），`--info-keyword ""` 清空全部 = 不过滤。

注意：secret 是敏感信息——含 secret 的 .zon 勿提交到仓库。

## 信息节点过滤

机场订阅常含"通知伪节点"（如 `到期2026-12-21 剩余流量279.95G`）——默认按强关键词自动过滤（`到期`/`剩余`/`有效期`/`套餐`/`官网` + `expire`/`traffic`/`usage`/`plan`），日志计数 `N info`，`-v` 列出被滤节点。可用 `info_node_keywords` 覆盖（空数组 = 不过滤）：

```zig
.{
    .info_node_keywords = .{ "到期", "剩余流量" },  // 自定义关键词（覆盖默认）
    .subscriptions = .{ ... },
}
```

## 模板（clash / singbox）

`-o clash:模板路径=输出` 或 `-o singbox:模板路径=输出` 使用自定义模板——模板是合法配置文件，节点部分用**单行空列表**占位，subfetch 填充：

```yaml
# clash 模板示例（其余部分完全保留，含注释）
mixed-port: 7890
dns:
  enable: true
proxies: []          # ← 填充点：节点列表
proxy-groups: []     # ← 可选：默认 PROXY/AUTO 组（缺失则自动追加）
rules: []            # ← 可选：默认 MATCH,PROXY（缺失则自动追加）
```

```json
// singbox 模板示例
{
  "log": { "level": "debug" },
  "inbounds": [{ "type": "mixed", "tag": "mixed-in", "listen": "0.0.0.0", "listen_port": 2080 }],
  "outbounds": [],   // ← 填充点：direct/block/PROXY selector + 节点
  "route": { "final": "PROXY", "auto_detect_interface": true }
}
```

规则：
- `proxies` / `"outbounds"` 填充点：必须是**单行空列表**（缺失或非空 → 报错）
- `proxy-groups` / `rules`：空列表 → 填默认（PROXY/AUTO 组、MATCH,PROXY）；**非空 → 保留用户内容**（可引用固定组名 PROXY/DIRECT）；缺失 → 自动追加默认
- 自定义 proxy-groups 时，用锚点 `- __NODES__` 标记节点名插入位置（宏展开，缩进对齐）；无锚点则组内列表完全由用户掌控（`proxies: []` 保持空，不会自动填）
- 节点块缩进自动模仿模板的缩进风格
- 无模板时使用内置默认模板（同一机制）

## 输出格式

| `-o` 格式 | 说明 | 校验 |
|---|---|---|
| `clash` | mihomo / clash 聚合配置 | `mihomo -t` |
| `singbox` | sing-box 聚合配置（clash_api 可选） | `sing-box check` |
| `trojan` | trojan-go 每节点一个配置 | JSON 语法 |
| `hysteria` | hysteria 1.x 每节点一个配置 | JSON 语法 |
| `hysteria2` | hysteria 2.x 每节点一个配置（YAML） | libyaml 解析 |
| `xray` | xray-core 每节点一个配置（vless） | `xray -test -c` |
| `ss` | shadowsocks-libev/rust 每节点一个配置 | JSON 语法 |
| `ssr` | shadowsocksr-libev 每节点一个配置 | JSON 语法 |
| `raw` | 节点 JSON 列表（脚本消费；无 `-o` 时的默认格式） | — |

原生格式（多文件）输出：**每节点一个配置文件**（文件名即节点名，如 `香港1.json`），当前激活节点由你自己的服务脚本管理。

注意：sing-box 不支持 ssr / v2ray-plugin，这些节点会被跳过并在日志提示。

## CLI 参数

```
-c, --config <path>    订阅列表 zon（默认 ./subscriptions.zon）
-o, --out <fmt>[:<tmpl>][=<path>]  输出目标（可多次；缺省默认 raw）
                        fmt: clash|singbox|trojan|hysteria|hysteria2|xray|ss|ssr|raw
                        tmpl: 模板文件（clash/singbox，可选）
                        path: 输出文件（单文件格式）或目录（原生格式）；'-' = stdout
    --node <uri>       直接粘贴节点 URI（可多次）
    --node-file <path> 节点列表文件（每行一个 URI）
    --dry-run          只校验不写文件（path 可省略；正式运行 path 必填）
    --ua <str>         默认 User-Agent
    --sep <str>        节点名前缀分隔符（默认 @）
    --timeout <sec>    单订阅拉取超时秒数
    --listen <addr>    原生客户端监听地址（默认 127.0.0.1）
    --port <n>         原生客户端监听端口（默认 1080）
    --mixed-port <n>   clash mixed-port（默认 65500）
    --controller <a:p> clash/singbox external-controller（默认 127.0.0.1:65501）
    --secret <str>     API secret（缺省自动生成 UUID）
    --no-clash-api     sing-box 不启用 clash_api
    --no-verify        跳过校验
    --no-reload        安装后不热重载
    --reload-cmd <cmd> 安装后执行自定义 reload 命令（sh -c，覆盖自动重载；acme.sh 风格）
-v, --verbose          详细输出
-h, --help             帮助
```

## 协议支持矩阵

| 协议 | URI 解析 | clash 输出 | sing-box 输出 | 原生输出 |
|---|---|---|---|---|
| vless（reality/tls/ws/grpc） | ✅ | ✅ | ✅ | ✅ xray |
| vmess | ✅ | ✅ | ✅ | — |
| trojan（ws/grpc） | ✅ | ✅ | ✅ | ✅ trojan-go |
| ss（obfs-local/v2ray-plugin/shadow-tls） | ✅ | ✅ | ✅ | ✅ sslocal |
| ssr | ✅ | ✅ | ❌ 跳过 | ✅ shadowsocksr |
| hysteria 1.x | ✅ | ✅ | ✅ | ✅ hy1 |
| hysteria 2.x（obfs） | ✅ | ✅ | ✅ | ✅ hy2 |
| tuic | ✅ | ✅ | ✅ | — |

不支持的协议（anytls / wireguard / AEAD-2022 明文链接等）会按行跳过并在日志提示。

## 平台支持

| 平台 | 支持 | 说明 |
|---|---|---|
| Linux | ✅ 目标平台 | 全功能；x86_64 / aarch64 / arm(ARMv6+) / riscv64 静态二进制 |
| macOS / Windows | ❌ 非目标 | 代码保持可编译但不发布；本工具是 ss-tproxy 工具链一环（无分流纯客户端配置，L4/DNS 分流由 ss-tproxy 负责，Linux Only） |

## 与现有项目的关系

- **subconverter**（★16.9k）：在线转换 API 服务，客户端把它当订阅源；subfetch 是本地 CLI 部署工具，一条命令完成拉取→校验→原子安装→热重载
- **Sub-Store**（★10.2k）：Web 订阅管理器（QX/Loon/Surge 生态）；subfetch 面向服务器/路由器脚本化部署，单二进制零依赖

## 目录结构

```
src/
├── main.zig           CLI 入口（参数/编排/安装流程）
├── config.zig         subscriptions.zon 解析（std.zon 类型安全）
├── fetch.zig          std.http.Client 拉取 + 线程超时
├── sniff.zig          订阅格式自动探测
├── uri.zig            8 协议 URI 解析（手动 authority 解析）
├── node.zig           节点模型（8 协议 tagged union）
├── parse.zig          订阅编排 + clash YAML/JSON 转换
├── yaml.zig           libyaml 封装（vendor 捆绑）
├── util.zig           base64/percent 解码
├── template.zig       模板机制（填充点/锚点/缩进探测）
├── render.zig         格式分发 + 节点名处理 + JSON 序列化
├── render_clash.zig   mihomo YAML 渲染
├── render_singbox.zig sing-box JSON 渲染
├── render_native.zig  原生客户端渲染（trojan/hy1/hy2/xray/ss/ssr）
├── render_raw.zig     raw JSON 渲染
└── deploy.zig        校验/原子安装/热重载
vendor/libyaml/        libyaml（MIT，捆绑静态编译）
```

## License

MIT
