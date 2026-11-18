# 计划：src2linyaps.debug — webhook upstream 源码获取与构建工具选择

## 目标

在 `skills/src2linyaps.debug/SKILL.md` 阶段四中增加：
1. webhook upstream 源码获取逻辑（4.1.0）
2. 构建工具选择逻辑（4.1.1）— pak_linyaps（binary）与 ll-builder（source）
3. 根据 build_tool 分支更新构建执行（4.1.2）、运行验证（4.2）
4. 更新目录约定与约束

## 设计决策

### 源文件获取（4.1.0）

- 优先级：用户指定 `src_path`/`src_url` > `skill()` 调用 `linyaps-upstream-query` 查询；用户指定时直接使用不调 upstream，两者均无时才调
- `linyaps-upstream-query` 输出 JSON：`{tasks:[{pkgName, src_url, arch, orig_version}], errors:[{pkgName, error}]}`
- skill 不会覆写输入已有字段（既有字段优先），仅补缺失字段
- 查询失败时（`errors`）跳过源文件获取，不阻塞构建
- `linyaps-upstream-query` 内部完成查询、下载、解压，返回字段供调用方使用

### 构建工具选择（4.1.1）

- 检测条件：项目目录有 `pak_linyaps.sh` → binary（pak_linyaps）；否则 → source（ll-builder）

### binary 分支（pak_linyaps）

- LLM **必须先读取 `pak_linyaps.sh` 脚本**理解参数，再构造调用命令
- 参考调用模式（来自 `linglong-binary-runner/scripts/run_tasks.sh` L191-195）：
  ```bash
  ./pak_linyaps.sh --linyaps_arch=<arch> --origin_version=<orig_version> \
    --src_path=<src_path> --output_dir=<output_dir> [--build_tmp_dir=<tmp>]
  ```
- 构建成功标志：`output_dir` 下 `*_binary.layer` 文件
- 重试 ≤ 2 次，单次超时 1800 秒，退出码 124 消歧

### source 分支（ll-builder）

- 保持现有逻辑不变：`ll-builder build --skip-output-check` + `ll-builder export --layer --no-develop -z zstd`
- 构建成功标志：`*.layer` 文件
- 重试 ≤ 2 次，单次超时 1800 秒，退出码 124 消歧

### 运行验证（4.2）

- binary 分支：LLM 读取 `linglong.yaml` 的 `command` 字段构造运行命令，从 `output_dir` 运行 layer
- source 分支：`ll-builder run --build-dir <project_path>`
- 共享：超时 30 秒，退出码 0/124 = 通过，构建失败时跳过

## 两个分支共享逻辑

- 退出码 124 消歧：检查 `ll-builder` / `fuse-overlayfs` / `erofsfuse` 进程是否仍活跃
- 重试 ≤ 2 次（含首次）
- `.layer` 文件检测：仅取本轮构建开始后生成的（`-newermt "@$start_time"`）

## 目录约定更新

在 `## 目录约定` 块追加：
- upstream 源文件获取：通过 `skill()` 调用 `linyaps-upstream-query` skill 查询；用户指定的 `src_path`/`src_url` 优先，upstream 查询仅补缺。

## 修改文件

- `skills/src2linyaps.debug/SKILL.md` — 唯一修改文件

## 参考文件（只读）

- `for-multica/skills/linyaps-upstream-query/scripts/query_upstream.sh` — webhook API URL 与字段映射
- `examples/.../linglong-binary-runner/scripts/run_tasks.sh` — pak_linyaps 调用模式
- `examples/.../linglong-source-updater/scripts/download-and-checksum.sh` — 下载+解压模式
