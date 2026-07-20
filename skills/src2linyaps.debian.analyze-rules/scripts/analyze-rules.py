#!/usr/bin/env python3
"""
analyze-rules.py — 分析 debian/rules 和 debian/ 目录中的资源文件，输出最终 YAML。

用法:
    python3 analyze-rules.py <project_path> <debian_path> [control_yaml]

输出 (stdout, YAML格式):
    包含 build_tool, build_args, baseline, resources 等的完整 YAML
"""

import sys
import os
import re
import yaml
import glob as glob_mod


def parse_changelog(changelog_path: str) -> str:
    """Extract the version from the first entry of debian/changelog."""
    if not os.path.exists(changelog_path):
        return ''
    with open(changelog_path, 'r', encoding='utf-8') as f:
        first_line = f.readline().strip()
    # Format: "pkgname (version) distribution; urgency=..."
    m = re.match(r'^[^()]+\(([^)]+)\)', first_line)
    return m.group(1).strip() if m else ''


def detect_build_tool_from_rules(rules_path: str, project_path: str) -> str:
    """Detect build tool type from debian/rules content or project files."""
    if os.path.exists(rules_path):
        with open(rules_path, 'r', encoding='utf-8') as f:
            content = f.read()
        # Check for dh sequences that indicate build tool
        if 'dh_auto_configure' in content or 'dh $@' in content:
            if os.path.exists(os.path.join(project_path, 'CMakeLists.txt')):
                return 'cmake'
            if os.path.exists(os.path.join(project_path, 'meson.build')):
                return 'meson'
            # Check dh sequence packages
            if 'dh-sequence-kf' in content or 'cmake' in content:
                return 'cmake'
            if 'dh-sequence-python' in content or 'dh_auto_configure' in content:
                # Default dh_auto_configure uses cmake if CMakeLists.txt exists
                if os.path.exists(os.path.join(project_path, 'CMakeLists.txt')):
                    return 'cmake'
                if os.path.exists(os.path.join(project_path, 'configure')):
                    return 'autotools'
                return 'make'

    # Fallback: scan project root for build files
    if os.path.exists(os.path.join(project_path, 'CMakeLists.txt')):
        return 'cmake'
    if os.path.exists(os.path.join(project_path, 'meson.build')):
        return 'meson'
    if os.path.exists(os.path.join(project_path, 'Makefile')) or \
       os.path.exists(os.path.join(project_path, 'GNUmakefile')):
        return 'make'
    if os.path.exists(os.path.join(project_path, 'configure')) or \
       os.path.exists(os.path.join(project_path, 'configure.ac')):
        return 'autotools'

    return 'unknown'


def extract_build_args_from_rules(rules_path: str, build_tool: str) -> list:
    """Extract build arguments from debian/rules override sections."""
    args = []
    if build_tool == 'cmake':
        common = [{'name': 'CMAKE_INSTALL_PREFIX', 'default': '/usr'},
                  {'name': 'CMAKE_BUILD_TYPE', 'default': 'Release'}]
        if os.path.exists(rules_path):
            with open(rules_path, 'r', encoding='utf-8') as f:
                content = f.read()
            # Look for override_dh_auto_configure
            m = re.search(r'override_dh_auto_configure\s*\n(.*?)(?=\n\S|\Z)', content, re.DOTALL)
            if m:
                block = m.group(1)
                for line in block.split('\n'):
                    for a in common:
                        pattern = r'-D' + re.escape(a['name']) + r'=(\S+)'
                        vm = re.search(pattern, line)
                        if vm:
                            a['default'] = vm.group(1)
        return common
    elif build_tool == 'meson':
        return [{'name': 'prefix', 'default': '/usr'},
                {'name': 'buildtype', 'default': 'debugoptimized'}]
    elif build_tool == 'autotools':
        return [{'name': 'prefix', 'default': '/usr'},
                {'name': 'host', 'default': ''}]
    else:
        return [{'name': 'prefix', 'default': '/usr/local'},
                {'name': 'DESTDIR', 'default': ''}]


def scan_resource_files(debian_path: str) -> dict:
    """Scan debian/*.install, *.links, *.docs, *.manpages files and aggregate resources."""
    resources = {}
    patterns = {
        'install': '*.install',
        'links': '*.links',
        'docs': '*.docs',
        'manpages': '*.manpages',
    }

    for res_type, pattern in patterns.items():
        items = []
        for fpath in glob_mod.glob(os.path.join(debian_path, pattern)):
            # Skip if it's a per-binary-package file (e.g., kate.install, kate-data.install)
            # We aggregate all of them
            with open(fpath, 'r', encoding='utf-8') as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith('#'):
                        items.append(line)
        # Deduplicate while preserving order
        seen = set()
        unique_items = []
        for item in items:
            if item not in seen:
                seen.add(item)
                unique_items.append(item)
        if unique_items:
            resources[res_type] = unique_items

    # Parse install resources into structured src/dest format
    if 'install' in resources:
        structured = []
        for entry in resources['install']:
            parts = entry.split()
            if len(parts) == 2:
                structured.append({'src': parts[0], 'dest': parts[1]})
            elif len(parts) == 1:
                structured.append({'src': parts[0], 'dest': ''})
        if structured:
            resources['install'] = structured

    return resources


def extract_build_depends_from_rules(rules_path: str, control_depends: list = None) -> list:
    """Merge build depends from control with any additional ones from rules."""
    return control_depends or []


def analyze(project_path: str, debian_path: str, control_info: dict = None) -> dict:
    """Main analysis function."""
    rules_path = os.path.join(debian_path, 'rules')
    changelog_path = os.path.join(debian_path, 'changelog')

    # Detect build tool
    build_tool = detect_build_tool_from_rules(rules_path, project_path)

    # Extract baseline
    baseline = parse_changelog(changelog_path)

    # Extract build args
    build_args = extract_build_args_from_rules(rules_path, build_tool)

    # Scan resource files
    resources = scan_resource_files(debian_path)

    # Build result
    result = {
        'build_tool': build_tool,
        'build_tool_type': build_tool,
        'baseline': baseline,
        'build_args': build_args,
    }

    if resources:
        result['resources'] = resources

    # Merge control info if provided
    if control_info:
        result['pkgName'] = control_info.get('pkgName', '')
        result['pkgDescription'] = control_info.get('pkgDescription', '')
        result['build_depends'] = control_info.get('buildDepends', [])

    return result


def main():
    if len(sys.argv) < 3:
        print("用法: python3 analyze-rules.py <project_path> <debian_path> [control_yaml_path]", file=sys.stderr)
        sys.exit(1)

    project_path = sys.argv[1]
    debian_path = sys.argv[2]

    control_info = None
    if len(sys.argv) >= 4:
        control_yaml_path = sys.argv[3]
        if os.path.exists(control_yaml_path):
            with open(control_yaml_path, 'r', encoding='utf-8') as f:
                control_info = yaml.safe_load(f)

    result = analyze(project_path, debian_path, control_info)
    print(yaml.dump(result, default_flow_style=False, allow_unicode=True, sort_keys=False))


if __name__ == '__main__':
    main()