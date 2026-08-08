# 实施进度

## 阶段一：渲染层重构（完成）

- [x] Renderer 统一接口（name / supported / render → []File）——render() 返回 []const File
- [x] 消除 union{single, files} → 统一 []File（clash/singbox/raw = 单元素）
- [x] main.zig 部署逻辑一套代码（循环 File[]：verify → 落盘 → reload）
- [ ] 多目标 -o a -o b：全部 verify 通过 → 统一落地（原子性）——待阶段二 CLI 重构后落实

## 阶段二：CLI 重构（完成）

- [x] -o/--out <format>[:<template>][=<path>]（可重复）
- [x] 删除 --output-format / --output / -o 旧语义
- [x] dry-run path 可选；正式 path 必填（报错）；无 -o 默认 raw
- [x] 路径语义自动区分（单文件=文件路径 / 多文件=目录）
- [x] 日志统一走 stderr（stdout 留给数据/`-` 输出）；-vv 简化（verbose=1）
- [x] 阶段一遗留：多目标 -o a -o b 全部 verify 通过 → 统一落地（原子性）

## 阶段三：模板机制（完成）

- [x] 单行空列表填充点：proxies: [] / "outbounds": []
- [x] 定位（键+冒号+空白+[]）+ 缩进探测模仿（template.zig：fillList/detectIndent）
- [x] 非空/缺失 → 报错（MissingFillPoint/NonEmptyList）；无模板 → 内置默认模板同路径
- [x] clash YAML / singbox JSON 统一文本级替换（src/template.zig）
- [x] clash 补充：proxy-groups/rules 空则填充、缺失则追加

## 阶段四：去重下放 + filter 显式化（完成）

- [x] 去重从 main 全局预处理 → render() 层统一（raw 保留原名，数据导出不处理）
- [x] supports() 协议级 filter 显式化，verbose 提示跳过数

## 不变项

- native：固定结构（无模板）；raw：数据导出
- verify/reload 机制复用
