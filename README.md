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
zig build test                          # 单元测试（84 个）
```

产物在 `zig-out/bin/subfetch`。

## 快速开始

```sh
# 1. 复制模板并编辑订阅列表（名称/URL/UA/开关）
cp subscriptions.example.zon subscriptions.zon
vim subscriptions.zon

# 2. 预览（dry-run：打印配置并校验，不写文件）
subfetch --config subscriptions.zon --out clash --dry-run

# 3. 安装并重载
subfetch --config subscriptions.zon --out clash \
    -o /etc/clash/config.yaml --reload-cmd "systemctl restart clash"
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

`url` 支持 `https://`、`http://`、`file://`、本地文件路径。节点名格式：`订阅名｜节点名`（分隔符可用 `--sep` 修改）。

## 输出格式

| `--out` | 说明 | 校验 |
|---|---|---|
| `clash` | mihomo / clash 聚合配置（默认） | `mihomo -t` |
| `singbox` | sing-box 聚合配置（clash_api 可选） | `sing-box check` |
| `trojan` | trojan-go 每节点一个配置 | JSON 语法 |
| `hysteria` | hysteria 1.x 每节点一个配置 | JSON 语法 |
| `hysteria2` | hysteria 2.x 每节点一个配置（YAML） | libyaml 解析 |
| `xray` | xray-core 每节点一个配置（vless） | `xray -test -c` |
| `ss` | shadowsocks-libev/rust 每节点一个配置 | JSON 语法 |
| `ssr` | shadowsocksr-libev 每节点一个配置 | JSON 语法 |
| `raw` | 节点 JSON 列表（脚本消费） | — |

原生格式（多文件）输出：每节点一个配置文件 + `current.json`（当前选择元信息）+ `current.conf.*`（当前节点配置副本，服务直接指向此文件）。

注意：sing-box 不支持 ssr / v2ray-plugin，这些节点会被跳过并在日志提示。

## CLI 参数

```
-c, --config <path>    订阅列表 zon（默认 ./subscriptions.zon）
    --out <fmt>        输出格式: clash|singbox|trojan|hysteria|hysteria2|xray|ss|ssr|raw
-o, --output <path>    输出文件（clash/singbox/raw）或输出目录（原生格式）
    --node <uri>       直接粘贴节点 URI（可多次）
    --node-file <path> 节点列表文件（每行一个 URI）
    --dry-run          只打印生成内容，不写文件
    --ua <str>         默认 User-Agent
    --sep <str>        节点名前缀分隔符（默认 ｜）
    --timeout <sec>    单订阅拉取超时秒数
    --listen <addr>    原生客户端监听地址（默认 127.0.0.1）
    --port <n>         原生客户端监听端口（默认 1080）
    --mixed-port <n>   clash mixed-port（默认 65500）
    --controller <a:p> clash/singbox external-controller（默认 127.0.0.1:65501）
    --secret <str>     API secret（缺省自动生成 UUID）
    --current <name>   原生格式当前节点（缺省第一个）
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
├── render.zig         格式分发 + 节点名处理
├── render_clash.zig   mihomo YAML 渲染
├── render_singbox.zig sing-box JSON 渲染
├── render_native.zig  原生客户端渲染（trojan/hy1/hy2/xray/ss/ssr）
├── render_raw.zig     raw JSON 渲染
└── install.zig        校验/原子安装/热重载
vendor/libyaml/        libyaml（MIT，捆绑静态编译）
```

## License

MIT
