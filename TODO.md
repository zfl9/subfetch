# subfetch — Zig 版开发 TODO

多订阅拉取 & 多格式配置生成工具（订阅 → clash / sing-box / trojan / hysteria / raw）
语言: Zig 0.15.2，单二进制零依赖，交叉编译 RPi (aarch64-linux-musl)

## 阶段 0: v1 存档与仓库整理
- [x] git init（main 分支）
- [x] TODO.md 建立
- [x] commit Python v1
- [x] v1 移入 legacy/，.gitignore 更新

## 阶段 1: Zig 项目骨架
- [x] zig init + build.zig（name=subfetch、musl、release 优化）
- [x] main.zig: CLI 参数（--config / --out / --node / --node-file / --dry-run / --output / --out-dir）
- [x] config.zig: 订阅配置解析（**.zon 格式**，std.zon.parse 原生支持，类型安全：未知字段/缺字段解析期报错）
- [x] fetch.zig: std.http.Client 拉取（https + 系统 CA；gzip/zstd 解压由 std 内置）
- [x] zig build 通过 + 冒烟测试（解析 fixtures/subscriptions.ini）
- [x] 每个模块带 test 块：`std.testing.refAllDecls(@This())` 引用全部声明，确保未引用 decl 也被编译；`zig build test` 全量验证

## 阶段 2: 解析层
- [x] node.zig: 节点模型（tagged union，协议异构字段归一化）
- [x] sniff.zig: 格式自动探测（base64 / JSON / YAML / URI 行，递归，HTML 拒绝）
- [x] uri.zig: 协议解析 ss / ssr / vmess / vless / trojan / hysteria / hysteria2 / tuic
- [x] libyaml 捆绑（vendor/ + @cImport）+ 订阅 YAML 解析封装
- [x] 单测: fixtures 各格式样例全覆盖（54 测试全过，冒烟 20 节点与 v1 一致）

## 阶段 3: 渲染层
- [x] render_clash.zig: config.yaml（手写 emitter，节点名/转义处理）
- [x] render_singbox.zig: config.json（outbounds + selector + clash_api 默认开）
- [x] render_trojan.zig / render_hysteria.zig / render_hysteria2.zig: 目录输出 + current.json/current.conf
- [x] render_raw.zig: 节点 JSON 列表
- [x] 输出定制字段（监听端口 / controller / secret / skip-cert-verify 等）
- [x] 真实客户端验证：mihomo -t / sing-box check / trojan-go 试运行 / hy1+hy2 配置加载（bin/ 目录）

## 阶段 4: 安装层与安全
- [x] 校验（clash -t / sing-box check，找不到二进制则跳过并警告；原生格式 JSON/yaml 语法校验）
- [x] 原子替换 + 备份 .bak（校验失败不动旧配置）
- [x] 热重载（clash/sing-box API PUT /configs，失败回退 systemctl；原生格式提示手动重启）
- [x] dry-run 全流程验证（生成内容也校验，失败即中止）
- [x] --timeout 实现（后台线程 + 超时检测，秒→毫秒换算）

## 阶段 5: 开源准备
- [x] README.md（用法 / 配置 / 输出格式说明）
- [x] LICENSE（MIT）
- [x] GitHub Actions 多平台构建（linux amd64/arm64/arm/riscv64、darwin、windows，交叉目标 qemu 冒烟）
- [x] 首次 release + 推送 GitHub（v0.1.1，7 平台二进制）

## 编码约定
- **测试分两种**，每个模块都必须有：
  1. `compile-check`：显式 `_ = &name;` 引用本文件**所有 fn/var**（含私有、含类型内嵌套 fn/var，如 `_ = &Node.name;`、`_ = &Config.deinit;`）。类型名不引用（编译期概念，无意义）；函数体内局部 decl 受 Zig 作用域限制无法外部引用，由行为测试调用覆盖。Zig 编译器是 lazy 的，必须显式引用才能尽早捕获编译错误
  2. 常规行为测试：功能验证（期望值断言、错误路径）
- 不造轮子：优先 std 标准库（zon/json/base64/http/Uri）；YAML 解析捆绑 libyaml（MIT，vendor/ 入仓）；输出 emitter 手写（输出结构固定）
- 默认 musl 静态链接单二进制（零外部依赖），交叉编译 `-Dtarget=aarch64-linux-musl`

## 备注
- v1 Python 版（legacy/）作为参考实现，解析逻辑平移
- 节点名 = 订阅名｜节点名（前缀），store-selected/组名稳定策略沿用 v1
