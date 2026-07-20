#!/usr/bin/env python3
"""
parse-control.py — 解析 debian/control 文件，提取结构化项目信息。

用法:
    python3 parse-control.py <control_file_path>

输出 (stdout, YAML格式):
    pkgName, pkgDescription, buildDepends[], binaryPackages[]
"""

import sys
import re
import yaml


def parse_control(filepath: str) -> dict:
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()

    result = {
        'pkgName': '',
        'pkgDescription': '',
        'buildDepends': [],
        'buildDependsArch': [],
        'buildDependsIndep': [],
        'binaryPackages': [],
    }

    # Split into paragraphs (separated by blank lines)
    paragraphs = re.split(r'\n\s*\n', content.strip())

    source_parsed = False
    all_build_depends = []
    all_build_depends_arch = []
    all_build_depends_indep = []

    for para in paragraphs:
        lines = para.strip().split('\n')
        # Continuation lines start with space
        field_values = {}
        current_field = None
        current_value = []

        for line in lines:
            if re.match(r'^[A-Za-z0-9][A-Za-z0-9\-]*:', line):
                if current_field:
                    field_values[current_field] = '\n'.join(current_value)
                current_field, _, val = line.partition(':')
                current_field = current_field.strip()
                current_value = [val.strip()]
            elif current_field and line.startswith(' ') or line.startswith('\t'):
                current_value.append(line.strip())
            else:
                # Continuation of previous value
                if current_value:
                    current_value.append(line)

        if current_field:
            field_values[current_field] = '\n'.join(current_value)

        # Source paragraph
        if 'Source' in field_values and not source_parsed:
            result['pkgName'] = field_values['Source'].split('\n')[0].strip()
            source_parsed = True

            for dep_field in ['Build-Depends', 'Build-Depends-Arch', 'Build-Depends-Indep']:
                if dep_field in field_values:
                    deps = parse_depends(field_values[dep_field])
                    key = 'buildDepends' if dep_field == 'Build-Depends' else (
                        'buildDependsArch' if dep_field == 'Build-Depends-Arch' else 'buildDependsIndep'
                    )
                    result[key] = merge_dedup(result[key], deps)

        # Package paragraphs
        if 'Package' in field_values:
            pkg_name = field_values['Package'].split('\n')[0].strip()
            result['binaryPackages'].append(pkg_name)

            # Take description from first package
            if not result['pkgDescription'] and 'Description' in field_values:
                desc = field_values['Description'].split('\n')[0].strip()
                result['pkgDescription'] = desc

            for dep_field in ['Build-Depends', 'Build-Depends-Arch', 'Build-Depends-Indep']:
                if dep_field in field_values:
                    deps = parse_depends(field_values[dep_field])
                    key = 'buildDepends' if dep_field == 'Build-Depends' else (
                        'buildDependsArch' if dep_field == 'Build-Depends-Arch' else 'buildDependsIndep'
                    )
                    result[key] = merge_dedup(result[key], deps)

    return result


def parse_depends(dep_str: str) -> list:
    """Parse a Build-Depends field value into a list of dependency strings."""
    # Remove line continuations and split by commas
    dep_str = dep_str.replace('\n', ' ').replace('|', ',')
    deps = []
    for part in dep_str.split(','):
        part = part.strip()
        if part and not part.startswith('#') and not part.startswith('<') and not part.startswith('['):
            deps.append(part)
    return deps


def merge_dedup(existing: list, new_items: list) -> list:
    """Merge two lists with deduplication, preserving order."""
    seen = set(existing)
    merged = list(existing)
    for item in new_items:
        if item not in seen:
            seen.add(item)
            merged.append(item)
    return merged


def main():
    if len(sys.argv) < 2:
        print("用法: python3 parse-control.py <control_file_path>", file=sys.stderr)
        sys.exit(1)

    filepath = sys.argv[1]
    result = parse_control(filepath)
    print(yaml.dump(result, default_flow_style=False, allow_unicode=True, sort_keys=False))


if __name__ == '__main__':
    main()