# libyaml (vendored)

[yaml/libyaml](https://github.com/yaml/libyaml) **0.2.5** (2020-06-01, MIT License),
trimmed to the files required for building:

- `include/yaml.h` — public header
- `src/` — 8 C sources + yaml_private.h (version macros inlined, no config.h)

Bundled and statically compiled by subfetch (see `linkLibYaml` in `build.zig`);
no system libyaml installation needed.
