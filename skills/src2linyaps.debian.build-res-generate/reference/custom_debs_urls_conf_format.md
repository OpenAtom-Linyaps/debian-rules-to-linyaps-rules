# custom_debs_urls.conf 格式规范

## 格式示例

```bash
# 由用户提供或上层 agent 生成，传入 --custom-deb-urls
# 位于 linglong.yaml 同级目录，映射到容器 /project/linglong/
# 可人工编辑：增删改 URL 行后重新构建即可
CUSTOM_DEB_URLS=(
  "https://example.com/repo/libcustom1_1.0.0_amd64.deb"
  "https://example.com/repo/libcustom2_2.1.3%2bpatch1_amd64.deb"
)
```

## 格式规范表

| 部分 | 说明 |
|------|------|
| 3 行注释头 | 固定内容，标识用途、位置、可编辑提示 |
| `CUSTOM_DEB_URLS=(...)` | bash 数组，每行一个 URL（带引号） |
| URL 百分号编码 | `+` 编码为 `%2b`，空格编码为 `%20` 等（URL 标准编码） |

## 加载机制

`download_custom_debs.sh` 通过 `source "${SCRIPT_DIR}/custom_debs_urls.conf"` 加载 `CUSTOM_DEB_URLS` 数组。

加载前临时关闭 `set -u`，避免 conf 未定义数组时中断。

## 人工编辑规则

- 增删改 URL 行后重新构建即可（`ll-builder build` 会重新执行 `build:` 段）。
- 保持 3 行注释头 + `CUSTOM_DEB_URLS=(...)` 数组语法不变。
- 每个 URL 用双引号包裹，单独一行。
