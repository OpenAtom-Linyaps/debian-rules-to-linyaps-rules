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
        'buildDependsAlternatives': [],
        'buildDependsArchAlternatives': [],
        'buildDependsIndepAlternatives': [],
        'binaryPackages': [],
    }

    # Split into paragraphs (separated by blank lines)
    paragraphs = re.split(r'\n\s*\n', content.strip())

    source_parsed = False

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
                    deps, alts = parse_depends(field_values[dep_field])
                    base_key = 'buildDepends' if dep_field == 'Build-Depends' else (
                        'buildDependsArch' if dep_field == 'Build-Depends-Arch' else 'buildDependsIndep'
                    )
                    alt_key = base_key + 'Alternatives'
                    result[base_key] = merge_dedup(result[base_key], deps)
                    result[alt_key] = merge_dedup_alternatives(result[alt_key], alts)

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
                    deps, alts = parse_depends(field_values[dep_field])
                    base_key = 'buildDepends' if dep_field == 'Build-Depends' else (
                        'buildDependsArch' if dep_field == 'Build-Depends-Arch' else 'buildDependsIndep'
                    )
                    alt_key = base_key + 'Alternatives'
                    result[base_key] = merge_dedup(result[base_key], deps)
                    result[alt_key] = merge_dedup_alternatives(result[alt_key], alts)

    return result


def parse_depends(dep_str: str) -> tuple:
    """Parse a Build-Depends field value into (deps, alternatives) tuple.

    Returns:
        deps: list of individual dependency strings (first option from each or-group)
        alternatives: list of lists, each inner list is an or-group of alternatives
    """
    dep_str = dep_str.replace('\n', ' ')
    deps = []
    alternatives = []
    for part in dep_str.split(','):
        part = part.strip()
        if not part or part.startswith('#') or part.startswith('<') or part.startswith('['):
            continue
        if '|' in part:
            or_group = [p.strip() for p in part.split('|')]
            deps.append(or_group[0])
            alternatives.append(or_group)
        else:
            deps.append(part)
    return deps, alternatives


def merge_dedup(existing: list, new_items: list) -> list:
    """Merge two lists with deduplication, preserving order."""
    seen = set(existing)
    merged = list(existing)
    for item in new_items:
        if item not in seen:
            seen.add(item)
            merged.append(item)
    return merged


def merge_dedup_alternatives(existing: list, new_groups: list) -> list:
    """Merge alternative groups with deduplication, preserving order.

    Each group is a list of alternative package strings.
    Dedup is based on the first element (matching buildDepends entry).
    """
    seen = set(g[0] if g else '' for g in existing)
    merged = list(existing)
    for group in new_groups:
        if group and group[0] not in seen:
            seen.add(group[0])
            merged.append(group)
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