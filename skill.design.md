# debian-rules-to-linyaps-rules-skill设计
这个skill/agent主要用于分析项目源代码对应的debian构建规则和构建资源, 用于为玲珑构建项目生成构建、编译规则和通用资源(common-data)

## 子模块
 - debian-rules-test: 用于将debian构建规则和源代码组合，测试`sudo apt build-dep`是否可以在deepin25中完整安装`Build-Depends`
 - proj-info-analyze: 通过`debian/control`信息, 整理出构建此项目的基本信息(pkgName、pkgDescription)以及所需的`Build-Depends`
 - debian-rules-analyze: 用于分析项目源码、构建规则以及其他文件(post脚本等其他资源)，整理出不通过debuild编译构建时的有效构建参数
 - src-type-analyze(fallback): 当任务未检测到debian构建规则时, 采取fallback方案直接分析源代码所用构建工具类型(cmake、meson、make等)
 - src-build-args-analyze: 当直接分析项目时， 确认构建工具类型后， 根据构建配置文件来解析可修改的配置参数(CMakefiles、Makefile、meson.build等)

## 输入
 - debian构建规则
 - 项目源代码

## 产出
 - 整理后的项目构建规则文件，格式为yaml。主要记录这些内容(独立section): 项目源代码构建工具类型、可使用的编译参数并带有默认值、构建规则的debian工程baseline(基于`debian/changelog`)、debian工程源码名称

## workflow
### 带有debian构建规则的项目
`debian-rules-test`>>`proj-info-analyze`>>`debian-rules-analyze`

### 不提供debian构建规则的项目(fallback)
`src-type-analyze`>>`src-build-args-analyze`

## 约束
 - 传入的原始项目必须包含debian构建规则或构建配置文件(CMakefiles、Makefile、meson.build等)
 - 若传入的debian构建规则和源代码项目不匹配，则结束任务