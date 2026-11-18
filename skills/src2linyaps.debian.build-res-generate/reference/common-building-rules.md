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