#!/usr/bin/env python3
"""
generate-linglong-yaml.py — 基于 analyze-control 输出的依赖信息 + analyze-rules 输出的 build 段，
结合默认值配置，生成完整的 linglong.yaml。

用法:
    python3 generate-linglong-yaml.py \\
        --control-info <path> \\
        --build-section <string> \\
        --package-version <version> \\
        --output <path> \\
        [--defaults <path>] \\
        [--architecture <arch>] \\
        [--base <base>] \\
        [--runtime <runtime>] \\
        [--command <cmd>] \\
[--build-tool <tool>] \\
         [--reference <path>]
 
 取值优先级: CLI 显式参数 > defaults JSON > 硬编码默认值
 
 --build-tool: 构建工具类型 (cmake/meson/make/autotools/unknown)，由 detect-tool 提供
 --reference:  referance/common-building-rules.yaml 路径，默认自动定位到 skill 目录
 """

import argparse
import json
import os
import re
import sys
import yaml

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

SPDX_HEADER = """# SPDX-FileCopyrightText: 2023 UnionTech Software Technology Co., Ltd.
#
# SPDX-License-Identifier: LGPL-3.0-or-later
"""


class QuotedStr(str):
    """标记为 YAML 双引号标量的字符串"""


class LiteralBlock(str):
    """标记为 YAML 字面块标量 (|) 的字符串"""


def quoted_str_representer(dumper, data):
    return dumper.represent_scalar('tag:yaml.org,2002:str', data, style='"')


def literal_block_representer(dumper, data):
    return dumper.represent_scalar('tag:yaml.org,2002:str', data, style='|')


yaml.add_representer(QuotedStr, quoted_str_representer)
yaml.add_representer(LiteralBlock, literal_block_representer)


def strip_version_constraint(dep: str) -> str:
    dep = re.sub(r'\s*\([^)]*\)', '', dep).strip()
    dep = re.sub(r'\s*<[^>]+>', '', dep).strip()
    dep = re.sub(r'\s*\[[^\]]*\]', '', dep).strip()
    dep = re.sub(r':\w+$', '', dep).strip()
    return dep


def read_yaml(path: str) -> dict:
    with open(path, 'r', encoding='utf-8') as f:
        return yaml.safe_load(f)


def read_json(path: str) -> dict:
    with open(path, 'r', encoding='utf-8') as f:
        return json.load(f)


def get_value(cli_val, default_val):
    return cli_val if cli_val is not None else default_val


def add_section_breaks(yaml_str: str) -> str:
    top_level_keys = {'package', 'base', 'runtime', 'command', 'buildext', 'build'}
    lines = yaml_str.split('\n')
    result = []
    for line in lines:
        if line and not line.startswith(' ') and ':' in line:
            key = line.split(':')[0].strip()
            if key in top_level_keys:
                result.append('')
        result.append(line)
    return '\n'.join(result)


def replace_hardcoded_prefixes(s: str) -> str:
    patterns = [
        (r'(-DCMAKE_INSTALL_PREFIX=)(?!\$\{PREFIX\}|\$PREFIX)\S+', r'\1${PREFIX}'),
        (r'(-Dprefix=)(?!\$\{PREFIX\}|\$PREFIX)\S+', r'\1${PREFIX}'),
        (r'(--prefix=)(?!\$\{PREFIX\}|\$PREFIX)\S+', r'\1${PREFIX}'),
        (r'(?<![-\w])(prefix=)(?!\$\{PREFIX\}|\$PREFIX)\S+', r'\1${PREFIX}'),
        (r'(-DCMAKE_INSTALL_(?:BINDIR|LIBDIR|INCLUDEDIR|DATADIR|SYSCONFDIR|LOCALSTATEDIR|LIBEXECDIR|SBINDIR|MANDIR|DOCDIR|INFODIR)=)(?!\$\{PREFIX\}|\$PREFIX)/usr/', r'\1${PREFIX}/'),
        (r'(?<!-D)(--(?:bindir|libdir|sbindir|sysconfdir|datadir|includedir|libexecdir|localstatedir|mandir|docdir|infodir)=)(?!\$\{PREFIX\}|\$PREFIX)/usr/', r'\1${PREFIX}/'),
        (r'(DESTDIR=)(?!\$\{PREFIX\}|\$PREFIX)\S+', r'\1${PREFIX}'),
        (r'(INSTALL_ROOT=)(?!\$\{PREFIX\}|\$PREFIX)\S+', r'\1${PREFIX}'),
        (r'(?<![-\w])(PREFIX=)(?!\$\{PREFIX\}|\$PREFIX)\S+', r'\1${PREFIX}'),
        (r'(LIB_INSTALL_DIR=)(?!\$\{PREFIX\}|\$PREFIX)/usr/', r'\1${PREFIX}/'),
    ]
    for pattern, replacement in patterns:
        s = re.sub(pattern, replacement, s)
    return s


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
            errors.append(
                f"build section contains '{word}=<value>' "
                f"which is not allowed for build tool type '{build_tool}'"
            )
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


def build_yaml(data, build_section, version, architecture, base, runtime, command, with_deps):
    pkg_name = data.get('pkgName', '') or ''
    description = data.get('pkgDescription', '') or ''
    raw_build_depends = data.get('buildDepends', []) or []
    runtime_depends = data.get('runtimeDepends', []) or []

    build_depends = [strip_version_constraint(d) for d in raw_build_depends if strip_version_constraint(d)]

    build_section = build_section.replace('${prefix}', '${PREFIX}')
    build_section = replace_hardcoded_prefixes(build_section)
    if not build_section.endswith('\n'):
        build_section += '\n'
    build_section += 'touch ${PREFIX}/.linyaps_genius\n'
    build_section += 'chmod -R 755 ${PREFIX}\n'

    desc_value = LiteralBlock(description) if '\n' in description else QuotedStr(description)
    cmd_list = [QuotedStr(c) for c in command.split()] if command else [QuotedStr('bash')]

    result = {
        'version': QuotedStr(version),
        'package': {
            'id': QuotedStr(pkg_name),
            'name': QuotedStr(pkg_name),
            'version': QuotedStr(version),
            'kind': 'app',
            'architecture': architecture,
            'description': desc_value,
        },
        'base': base,
        'runtime': runtime,
        'buildext': {
            'apt': {},
        },
        'command': cmd_list,
        'build': LiteralBlock(build_section),
    }

    if with_deps:
        result['buildext']['apt']['build_depends'] = build_depends
        result['buildext']['apt']['depends'] = runtime_depends
    else:
        result['buildext']['apt']['depends'] = runtime_depends

    return result


def inject_args_to_configure(build_section: str, build_args: list, extra_args: str) -> str:
    """将 build_args 和 extra_args 注入到 build_section 的 configure 命令中。

    - build_args: 从 analyze-rules.py 提取的基础参数, 替换 configure 行中同名参数值
    - extra_args: LLM 语义分析得到的额外参数, 追加到 configure 行末尾
    - 空值参数自动省略
    """
    lines = build_section.split('\n')
    result = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith('./configure ') or stripped.startswith('cmake ') or stripped.startswith('meson '):
            for arg in build_args:
                name = arg.get('name', '')
                value = arg.get('default', '')
                if not value:
                    continue
                if stripped.startswith('./configure '):
                    pattern = rf'--{re.escape(name)}=\S+'
                    replacement = f'--{name}={value}'
                    if re.search(pattern, stripped):
                        stripped = re.sub(pattern, replacement, stripped)
                    else:
                        stripped += f' --{name}={value}'
                elif stripped.startswith('cmake '):
                    pattern = rf'-D{re.escape(name)}=\S+'
                    replacement = f'-D{name}={value}'
                    if re.search(pattern, stripped):
                        stripped = re.sub(pattern, replacement, stripped)
                    else:
                        stripped += f' -D{name}={value}'
                elif stripped.startswith('meson '):
                    pattern = rf'-D{re.escape(name)}=\S+'
                    replacement = f'-D{name}={value}'
                    if re.search(pattern, stripped):
                        stripped = re.sub(pattern, replacement, stripped)
                    else:
                        stripped += f' -D{name}={value}'
            if extra_args:
                stripped += f' {extra_args}'
            result.append(line.replace(line.strip(), stripped))
        else:
            result.append(line)
    return '\n'.join(result)


def supplement_build_section(build_section: str, build_tool: str, reference: dict) -> str:
    """检查 build_section 是否包含 reference 中定义的必选命令, 缺失则补充。"""
    if reference is None:
        return build_section
    tool_ref = reference.get('tools', {}).get(build_tool, {})
    if not tool_ref:
        return build_section

    commands = _split_commands(build_section)
    supplement_lines = []

    for cmd_def in tool_ref.get('commands', []):
        if not _matches_command_def(cmd_def, commands):
            desc = cmd_def.get('description', '')
            patterns = cmd_def.get('patterns', [])
            if 'one_of' in cmd_def:
                patterns = cmd_def['one_of'][0].get('patterns', [])
            if patterns:
                supplement_line = ' '.join(patterns)
                supplement_lines.append(supplement_line)
                print(f"  [supplement] added missing command: {desc}", file=sys.stderr)

    if supplement_lines:
        build_section = build_section.rstrip('\n') + '\n' + '\n'.join(supplement_lines) + '\n'

    return build_section


def generate_build_section_from_reference(build_tool: str, build_args: list, reference: dict) -> str:
    """从 common-building-rules.yaml 生成规范 build section 模板。"""
    if reference is None:
        return ''

    tool_ref = reference.get('tools', {}).get(build_tool, {})
    if not tool_ref:
        return ''

    lines = []
    for cmd_def in tool_ref.get('commands', []):
        patterns = cmd_def.get('patterns', [])
        if 'one_of' in cmd_def:
            patterns = cmd_def['one_of'][0].get('patterns', [])
        if patterns:
            exclude = cmd_def.get('exclude', [])
            cmd_str = ' '.join(p for p in patterns if p not in exclude)
            if cmd_str:
                lines.append(cmd_str)

    result = '\n'.join(lines)
    if build_args:
        result = inject_args_to_configure(result, build_args, '')
    return result


def main():
    parser = argparse.ArgumentParser(description='Generate linglong.yaml')
    parser.add_argument('--control-info', required=True)
    parser.add_argument('--build-section', default='')
    parser.add_argument('--package-version', default=None)
    parser.add_argument('--architecture', default=None)
    parser.add_argument('--base', default=None)
    parser.add_argument('--runtime', default=None)
    parser.add_argument('--command', default=None)
    parser.add_argument('--defaults', default='')
    parser.add_argument('--output', required=True)
    parser.add_argument('--build-tool', default='unknown',
                        choices=['cmake', 'meson', 'make', 'autotools', 'unknown'],
                        help='build tool type (from detect-tool)')
    parser.add_argument('--build-args', default='',
                        help='build args JSON from analyze-rules.py (e.g. \'[{"name":"prefix","default":"${PREFIX}"}]\')')
    parser.add_argument('--extra-args', default='',
                        help='extra configure args from LLM semantic analysis (e.g. "--enable-qt --enable-dbus")')
    parser.add_argument('--reference', default='',
                        help='path to referance/common-building-rules.yaml')
    args = parser.parse_args()

    control_info = read_yaml(args.control_info)

    defaults = {}
    if args.defaults and os.path.isfile(args.defaults):
        defaults = read_json(args.defaults)

    build_depends_raw = control_info.get('buildDepends', []) or []
    with_deps = bool(build_depends_raw)

    version = get_value(args.package_version, defaults.get('version', '0.0.0.1'))
    architecture = get_value(args.architecture, defaults.get('architecture', 'x86_64'))
    base = get_value(args.base, defaults.get('base', ''))
    runtime = get_value(args.runtime, defaults.get('runtime', ''))
    command = get_value(args.command, defaults.get('command', 'bash'))
    build_section = args.build_section if args.build_section else ''

    # Parse build_args
    build_args = []
    if args.build_args:
        try:
            build_args = json.loads(args.build_args)
        except json.JSONDecodeError as e:
            print(f"  [warn] failed to parse --build-args JSON: {e}", file=sys.stderr)

    # Load reference
    reference = load_reference(args.reference if args.reference else None)

    # Determine build_section: --build-section > reference generate > defaults fallback
    if not build_section and reference:
        build_section = generate_build_section_from_reference(args.build_tool, build_args, reference)
    elif not build_section:
        build_section = defaults.get('build_section_fallback', '')

    # Inject args into configure commands
    build_section = inject_args_to_configure(build_section, build_args, args.extra_args)

    # Supplement missing commands from reference
    if reference:
        build_section = supplement_build_section(build_section, args.build_tool, reference)

    # Check forbidden patterns (blocking errors)
    if reference:
        _, errors = check_against_reference(build_section, args.build_tool, reference)
        if errors:
            for e in errors:
                print(f"ERROR: {e}", file=sys.stderr)
            sys.exit(1)

    result = build_yaml(control_info, build_section, version, architecture, base, runtime, command, with_deps)

    raw = yaml.dump(result, default_flow_style=False, allow_unicode=True, sort_keys=False, width=4096)
    formatted = add_section_breaks(raw)

    os.makedirs(os.path.dirname(args.output) or '.', exist_ok=True)
    with open(args.output, 'w', encoding='utf-8') as f:
        f.write(SPDX_HEADER)
        f.write('\n')
        f.write(formatted)

    print(f"linglong.yaml generated: {args.output}")


if __name__ == '__main__':
    main()