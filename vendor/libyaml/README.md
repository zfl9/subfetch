# libyaml (vendor)

[yaml/libyaml](https://github.com/yaml/libyaml) **0.2.5**（2020-06-01，MIT License），仅保留构建所需文件：

- `include/yaml.h` — 公共头文件
- `src/` — 8 个 C 源文件 + yaml_private.h
- `config.h` — 静态配置（版本宏），构建参数 `-DHAVE_CONFIG_H=1` 需要
- `License` — MIT 许可原文

由 subfetch 捆绑静态编译（见 `build.zig` 的 `addLibyaml`），无需系统安装 libyaml。
