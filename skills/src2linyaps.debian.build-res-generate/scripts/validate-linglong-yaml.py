#!/usr/bin/env python3
"""
validate-linglong-yaml.py — 检测生成的 linglong.yaml 格式化与字段合法性。

检查项:
  - YAML 可解析
  - JSON 可序列化（模拟 ll-builder 的 nlohmann-json C++ 解析器）
  - command 为数组（非 string/null）
  - version / package.* 为字符串
  - base / runtime 非空字符串
  - buildext.apt 存在，build_depends 和 depends 为 list
  - build 为字符串
  - 无 sources 段（按约束）
  - build_depends 条目无版本约束残留
  - 无非法字段（基于 skills/config/linglong-schema.yaml 约束）
- build 段参考检查 + 禁用参数检查（基于 --build-tool 和 referance/common-building-rules.yaml）
 
 用法:
     python3 validate-linglong-yaml.py <path> [--schema <path>] [--build-tool <tool>] [--reference <path>]

退出码: 0 = 通过, 1 = 失败
"""

import argparse
import json
import os
import re
import sys
import yaml

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

COMMAND_MUST_BE_LIST = "field 'command' must be a list (not string/null/missing)"
VERSION_MUST_BE_STR = "field 'version' must be a string"
PACKAGE_MUST_HAVE = "package must have non-empty 'id', 'name', 'version', 'kind'"
BASE_RUNTIME_REQUIRED = "fields 'base' and 'runtime' must be non-empty strings"
BUILDEXT_APT_REQUIRED = "buildext.apt must be present"
DEPS_MUST_BE_LIST = "buildext.apt.{key} must be a list"
BUILD_MUST_BE_STR = "field 'build' must be a string"
NO_SOURCES = "sources section should not be present (use constraint)"
NO_VERSION_CONSTRAINT = "dep entry '{dep}' still contains version constraint"
UNKNOWN_TOP_LEVEL = "unknown top-level field '{key}' (not in schema allowed list)"
FORBIDDEN_PATH = "forbidden field path '{path}': {message}"
SCHEMA_NOT_FOUND = "schema file not found at {path}, skipping field legality checks"
HARDCODED_PREFIX = "field 'build' uses hardcoded path '{match}' instead of ${{PREFIX}}"
BLACKLIST_VIOLATION = "build section contains '{word}=<value>' which is not allowed for build tool type '{build_tool}'"


def load_schema(schema_path: str) -> dict | None:
    if not os.path.isfile(schema_path):
        print(f"  [warn] {SCHEMA_NOT_FOUND.format(path=schema_path)}", file=sys.stderr)
        return None
    with open(schema_path, 'r', encoding='utf-8') as f:
        return yaml.safe_load(f)


def check_top_level_keys(data: dict, schema: dict, errors: list):
    allowed = set(schema.get('top_level', {}).get('allowed', []))
    for key in data:
        if key not in allowed:
            errors.append(UNKNOWN_TOP_LEVEL.format(key=key))


def check_forbidden_paths(data, schema, errors, parent_path=""):
    forbidden_rules = schema.get('forbidden_paths', [])
    forbidden_map = {rule['path']: rule['message'] for rule in forbidden_rules}

    def _walk(obj, current_path):
        if not isinstance(obj, dict):
            return
        for key, value in obj.items():
            path = f"{current_path}.{key}" if current_path else key
            if path in forbidden_map:
                errors.append(FORBIDDEN_PATH.format(path=path, message=forbidden_map[path]))
            if isinstance(value, dict):
                _walk(value, path)

    _walk(data, parent_path)


def load_blacklist(path=None):
    if path is None:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        path = os.path.join(script_dir, '..', 'build-section-blacklist.yaml')
    if not os.path.isfile(path):
        return None
    with open(path, 'r', encoding='utf-8') as f:
        config = yaml.safe_load(f)
    return config.get('blacklist', {})


def check_blacklist(build_section, build_tool, blacklist):
    errors = []
    if build_tool not in blacklist:
        return errors
    forbidden = blacklist.get(build_tool, [])
    for word in forbidden:
        pattern = re.compile(rf'{re.escape(word)}=\S+')
        if pattern.search(build_section):
            errors.append(BLACKLIST_VIOLATION.format(word=word, build_tool=build_tool))
    return errors


def load_reference(path=None):
    if path is None:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        path = os.path.join(script_dir, '..', 'referance', 'common-building-rules.yaml')
    if not os.path.isfile(path):
        return None
    with open(path, 'r', encoding='utf-8') as f:
        return yaml.safe_load(f)


def _split_commands(text):
    text = re.sub(r'\\\n', ' ', text)
    parts = re.split(r'&&|;|\|\||\n', text)
    return [p.strip() for p in parts if p.strip()]


def _matches_command_def(cmd_def, commands):
    if 'one_of' in cmd_def:
        for alt in cmd_def['one_of']:
            patterns = alt.get('patterns', [])
            exclude = alt.get('exclude', [])
            for cmd in commands:
                if all(p in cmd for p in patterns):
                    if not any(e in cmd for e in exclude):
                        return True
        return False
    patterns = cmd_def.get('patterns', [])
    exclude = cmd_def.get('exclude', [])
    for cmd in commands:
        if all(p in cmd for p in patterns):
            if not any(e in cmd for e in exclude):
                return True
    return False


def check_against_reference(build_section, build_tool, reference):
    if reference is None:
        return [], []
    tool_ref = reference.get('tools', {}).get(build_tool, {})
    if not tool_ref:
        return [], []
    commands = _split_commands(build_section)
    warnings = []
    for cmd_def in tool_ref.get('commands', []):
        if not _matches_command_def(cmd_def, commands):
            warnings.append(
                f"build section: missing required command '{cmd_def['description']}'"
            )
    errors = []
    for fb in tool_ref.get('forbidden', []):
        fb_patterns = fb.get('patterns', [])
        if not fb_patterns:
            continue
        for cmd in commands:
            if all(p in cmd for p in fb_patterns):
                errors.append(
                    f"build section contains forbidden pattern: {fb['description']}"
                )
                break
    return warnings, errors


def validate(path: str, schema_path: str = "", build_tool: str = "unknown", reference=None) -> list:
    errors = []

    # 1. Parse YAML
    try:
        with open(path, 'r', encoding='utf-8') as f:
            data = yaml.safe_load(f)
    except yaml.YAMLError as e:
        return [f"YAML parse error: {e}"]

    if not isinstance(data, dict):
        return [f"Top-level must be a mapping, got {type(data).__name__}"]

    # 2. JSON serialization (simulates ll-builder nlohmann-json behavior)
    try:
        json.dumps(data)
    except (TypeError, ValueError) as e:
        errors.append(f"JSON serialization error: {e}")

    # 3. command must be a list
    cmd = data.get('command')
    if not isinstance(cmd, list):
        errors.append(f"{COMMAND_MUST_BE_LIST} (got {type(cmd).__name__}: {cmd!r})")
    else:
        for i, item in enumerate(cmd):
            if not isinstance(item, str):
                errors.append(f"command[{i}] must be a string, got {type(item).__name__}: {item!r}")

    # 4. version must be a string
    ver = data.get('version')
    if not isinstance(ver, str) or not ver:
        errors.append(f"{VERSION_MUST_BE_STR} (got {type(ver).__name__}: {ver!r})")

    # 5. package section
    pkg = data.get('package')
    if not isinstance(pkg, dict):
        errors.append(f"package must be a mapping, got {type(pkg).__name__}")
    else:
        for field in ('id', 'name', 'version', 'kind'):
            val = pkg.get(field)
            if not isinstance(val, str) or not val:
                errors.append(f"{PACKAGE_MUST_HAVE} (field '{field}' is {val!r})")

    # 6. base and runtime
    for field in ('base', 'runtime'):
        val = data.get(field)
        if not isinstance(val, str) or not val:
            errors.append(f"{BASE_RUNTIME_REQUIRED} (field '{field}' is {val!r})")

    # 7. buildext.apt
    buildext = data.get('buildext')
    if not isinstance(buildext, dict):
        errors.append(f"buildext must be a mapping, got {type(buildext).__name__}")
    else:
        apt = buildext.get('apt')
        if not isinstance(apt, dict):
            errors.append(f"{BUILDEXT_APT_REQUIRED} (got {type(apt).__name__})")
        else:
            for key in ('build_depends', 'depends'):
                val = apt.get(key)
                if val is not None and not isinstance(val, list):
                    errors.append(DEPS_MUST_BE_LIST.format(key=key))
                elif val is not None:
                    for i, entry in enumerate(val):
                        if not isinstance(entry, str):
                            errors.append(f"buildext.apt.{key}[{i}] must be a string")

    # 8. build must be a string
    build_val = data.get('build')
    if not isinstance(build_val, str):
        errors.append(f"{BUILD_MUST_BE_STR} (got {type(build_val).__name__})")
    else:
        # 8a. Check for hardcoded install paths in build section
        hardcoded_checks = [
            # prefix-level variables
            (r'-DCMAKE_INSTALL_PREFIX=/(?!\$\{PREFIX\}|\$PREFIX)', '-DCMAKE_INSTALL_PREFIX=<hardcoded_path>'),
            (r'-Dprefix=/(?!\$\{PREFIX\}|\$PREFIX)', '-Dprefix=<hardcoded_path>'),
            (r'(?<!-D)--prefix=/(?!\$\{PREFIX\}|\$PREFIX)', '--prefix=<hardcoded_path>'),
            (r'(?<![-\w])prefix=/(?!\$\{PREFIX\}|\$PREFIX)', 'prefix=<hardcoded_path>'),
            # CMake subdirectory install vars
            (r'-DCMAKE_INSTALL_(?:BINDIR|LIBDIR|INCLUDEDIR|DATADIR|SYSCONFDIR|LOCALSTATEDIR|LIBEXECDIR|SBINDIR|MANDIR|DOCDIR|INFODIR)=/(?!\$\{PREFIX\}|\$PREFIX)', '-DCMAKE_INSTALL_<DIR>=<hardcoded_path>'),
            # Autotools subdirectory options
            (r'(?<!-D)--(?:bindir|libdir|sbindir|sysconfdir|datadir|includedir|libexecdir|localstatedir|mandir|docdir|infodir)=/(?!\$\{PREFIX\}|\$PREFIX)', '--<dir>=<hardcoded_path>'),
            # DESTDIR for staging installs
            (r'DESTDIR=/(?!\$\{PREFIX\}|\$PREFIX)', 'DESTDIR=<hardcoded_path>'),
            # INSTALL_ROOT (used in some CMake projects)
            (r'INSTALL_ROOT=/(?!\$\{PREFIX\}|\$PREFIX)', 'INSTALL_ROOT=<hardcoded_path>'),
            # PREFIX uppercase (Makefile variable, case-sensitive gap)
            (r'(?<![-\w])PREFIX=/(?!\$\{PREFIX\}|\$PREFIX)', 'PREFIX=<hardcoded_path>'),
            # LIB_INSTALL_DIR (used in qmake / some CMake projects)
            (r'LIB_INSTALL_DIR=/(?!\$\{PREFIX\}|\$PREFIX)', 'LIB_INSTALL_DIR=<hardcoded_path>'),
        ]
        for pattern, display in hardcoded_checks:
            m = re.search(pattern, build_val)
            if m:
                errors.append(HARDCODED_PREFIX.format(match=display))

        # 8b. Check against reference (required commands + forbidden patterns)
        ref_warnings, ref_errors = check_against_reference(build_val, build_tool, reference)
        for w in ref_warnings:
            print(f"  [warn] {w}", file=sys.stderr)
        errors.extend(ref_errors)

    # 9. No sources section
    if 'sources' in data:
        errors.append(NO_SOURCES)

    # 10. build_depends entries with version constraints
    apt_raw = (data.get('buildext') or {}).get('apt') or {}
    if isinstance(apt_raw, dict):
        for dep in apt_raw.get('build_depends') or []:
            if isinstance(dep, str):
                if re.search(r'\([^)]*\)', dep) or re.search(r'[><=!]', dep):
                    errors.append(NO_VERSION_CONSTRAINT.format(dep=dep))

    # 11. Schema-based field legality checks
    if schema_path:
        schema = load_schema(schema_path)
        if schema:
            check_top_level_keys(data, schema, errors)
            check_forbidden_paths(data, schema, errors)

    return errors


def default_schema_path() -> str:
    script_dir = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(script_dir, '..', '..', '..', 'skills', 'config', 'linglong-schema.yaml')


def main():
    parser = argparse.ArgumentParser(description='Validate linglong.yaml formatting')
    parser.add_argument('path', help='Path to linglong.yaml')
    parser.add_argument('--schema', default='',
                        help='Path to schema constraint file (default: auto-detect)')
    parser.add_argument('--build-tool', default='unknown',
                        choices=['cmake', 'meson', 'make', 'autotools', 'unknown'],
                        help='build tool type (from detect-tool)')
    parser.add_argument('--reference', default='',
                        help='path to referance/common-building-rules.yaml')
    args = parser.parse_args()

    schema_path = args.schema or default_schema_path()
    reference_path = args.reference or ''
    reference = load_reference(reference_path if reference_path else None)

    errors = validate(args.path, schema_path, args.build_tool, reference)

    if errors:
        print(f"FAIL: {len(errors)} issue(s) found", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        sys.exit(1)
    else:
        print("PASS: linglong.yaml format is valid")
        sys.exit(0)


if __name__ == '__main__':
    main()