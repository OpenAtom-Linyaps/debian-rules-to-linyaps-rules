# 常见编译规则
## qmake
```bash
	qmake -r CONFIG+=release PREFIX="${PREFIX}"
	make
	DESTDIR="${PREFIX}" make install
```

## meson
```bash
	 meson build \
 --prefix="${PREFIX}" \
 -Denable_tests=false
```

## cmake
```bash
	cmake \
 -DCMAKE_BUILD_TYPE=Release \
 -DCMAKE_INSTALL_PREFIX="${PREFIX}"
	make
	make install
```

## autotools
```bash
	./configure \
 --prefix="${PREFIX}"
```

## make
```bash
	make
	DESTDIR="${PREFIX}" make install
```

## 安装目录映射

安装目录变量必须映射到正确的 `${PREFIX}` 子目录：

| 类别 | 允许路径 | CMake 变量 | Autotools 选项 |
|------|----------|-----------|---------------|
| 二进制 | `${PREFIX}/bin` | `CMAKE_INSTALL_BINDIR`, `KDE_INSTALL_BINDIR` | `--bindir` |
| 库 | `${PREFIX}/lib` | `CMAKE_INSTALL_LIBDIR`, `KDE_INSTALL_LIBDIR`, `LIB_INSTALL_DIR` | `--libdir` |
| 通用资源 | `${PREFIX}/share` | `CMAKE_INSTALL_DATADIR`, `CMAKE_INSTALL_DATAROOTDIR`, `KDE_INSTALL_DATADIR`, `KDE_INSTALL_DATAROOTDIR`, `SHARE_INSTALL_DIR`, `DATA_INSTALL_DIR` | `--datadir`, `--datarootdir` |

- 生成阶段自动修正错误子目录（如 `${PREFIX}/games` → `${PREFIX}/bin`），打印 `[normalize]` 提示
- 校验阶段检测并阻断错误子目录
- 严格匹配：`${PREFIX}/lib/x86_64-linux-gnu` 不被允许（玲珑用扁平文件系统）
- 映射规则定义在 `common-building-rules.yaml` 的 `install_dir_mapping` 键