#!/bin/bash
# test-build-deps.sh — 检测 debian/control 中 Build-Depends 的可用性
# 使用 apt-get build-dep --dry-run 非交互式检测，不实际安装
#
# 用法:
#   sudo bash test-build-deps.sh <project_path>
#
# 输出 (stdout, JSON):
#   { "status": "available"|"partial"|"unavailable",
#     "available_pkgs": [...],
#     "missing_pkgs": [...],
#     "raw_build_depends": [...] }

set -euo pipefail

PROJECT_PATH="${1:-}"
if [ -z "$PROJECT_PATH" ]; then
    echo '{"status":"error","error":"用法: test-build-deps.sh <project_path>"}'
    exit 1
fi

DEBIAN_DIR="$PROJECT_PATH/debian"
CONTROL_FILE="$DEBIAN_DIR/control"

if [ ! -f "$CONTROL_FILE" ]; then
    echo '{"status":"error","error":"debian/control 文件不存在"}'
    exit 1
fi

# Extract raw Build-Depends field (handle multiline)
RAW_BUILD_DEPENDS=$(awk '
    /^Build-Depends:/ { found=1; sub(/^Build-Depends:[[:space:]]*/, ""); line=$0; }
    found && /^[[:space:]]/ { line=line " " $0; }
    found && /^[A-Za-z]/ && !/^Build-Depends:/ { found=0; }
    found { gsub(/\n/, "", line); printf "%s", line; }
' "$CONTROL_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

# Also check Build-Depends-Arch and Build-Depends-Indep
RAW_BD_ARCH=$(awk '
    /^Build-Depends-Arch:/ { found=1; sub(/^Build-Depends-Arch:[[:space:]]*/, ""); line=$0; }
    found && /^[[:space:]]/ { line=line " " $0; }
    found && /^[A-Za-z]/ && !/^Build-Depends-Arch:/ { found=0; }
    found { gsub(/\n/, "", line); printf "%s", line; }
' "$CONTROL_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

RAW_BD_INDEP=$(awk '
    /^Build-Depends-Indep:/ { found=1; sub(/^Build-Depends-Indep:[[:space:]]*/, ""); line=$0; }
    found && /^[[:space:]]/ { line=line " " $0; }
    found && /^[A-Za-z]/ && !/^Build-Depends-Indep:/ { found=0; }
    found { gsub(/\n/, "", line); printf "%s", line; }
' "$CONTROL_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

# Combine all build depends
ALL_BD=""
[ -n "$RAW_BUILD_DEPENDS" ] && ALL_BD="$RAW_BUILD_DEPENDS"
[ -n "$RAW_BD_ARCH" ] && ALL_BD="${ALL_BD:+$ALL_BD, }$RAW_BD_ARCH"
[ -n "$RAW_BD_INDEP" ] && ALL_BD="${ALL_BD:+$ALL_BD, }$RAW_BD_INDEP"

# Split by comma and clean up each dep
RAW_DEPS=()
IFS=',' read -ra PARTS <<< "$ALL_BD"
for part in "${PARTS[@]}"; do
    dep=$(echo "$part" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^#\|^<\|^\[' || true)
    [ -n "$dep" ] && RAW_DEPS+=("$dep")
done

# Create JSON array of raw build depends
RAW_JSON="["
FIRST=true
for dep in "${RAW_DEPS[@]}"; do
    $FIRST || RAW_JSON+=", "
    FIRST=false
    # Escape JSON
    dep_escaped=$(echo "$dep" | sed 's/"/\\"/g')
    RAW_JSON+="\"$dep_escaped\""
done
RAW_JSON+="]"

# Run apt-get build-dep --dry-run
# Redirect stderr to capture error messages
TEMP_OUTPUT=$(mktemp)
TEMP_ERROR=$(mktemp)
set +e
DEBIAN_FRONTEND=noninteractive apt-get build-dep --dry-run ./ 2>"$TEMP_ERROR" >"$TEMP_OUTPUT"
APT_EXIT_CODE=$?
set -e

AVAILABLE_PKGS=()
MISSING_PKGS=()

if [ $APT_EXIT_CODE -eq 0 ]; then
    STATUS="available"
    # Parse "The following NEW packages will be installed:" section
    IN_NEW_PKGS=false
    while IFS= read -r line; do
        if echo "$line" | grep -q "The following NEW packages will be installed:"; then
            IN_NEW_PKGS=true
            continue
        fi
        if $IN_NEW_PKGS; then
            # Stop at empty line or other sections
            if [ -z "$(echo "$line" | tr -d '[:space:]')" ] || echo "$line" | grep -q "packages will be"; then
                IN_NEW_PKGS=false
                continue
            fi
            # Extract package names (lines may start with spaces, contain multiple packages)
            for pkg in $(echo "$line" | sed 's/^[[:space:]]*//'); do
                [ -n "$pkg" ] && AVAILABLE_PKGS+=("$pkg")
            done
        fi
    done < "$TEMP_OUTPUT"
else
    # Extract missing packages from error messages
    while IFS= read -r line; do
        if echo "$line" | grep -q "E: Unable to locate package"; then
            pkg=$(echo "$line" | sed 's/.*E: Unable to locate package //' | sed 's/[[:space:]]*$//')
            [ -n "$pkg" ] && MISSING_PKGS+=("$pkg")
        fi
    done < "$TEMP_ERROR"

    if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
        if [ ${#AVAILABLE_PKGS[@]} -gt 0 ]; then
            STATUS="partial"
        else
            STATUS="unavailable"
        fi
    else
        STATUS="unavailable"
        # Try to extract more info from error
        ERROR_MSG=$(cat "$TEMP_ERROR" | tr '\n' ' ' | sed 's/"/\\"/g')
        MISSING_PKGS+=("apt_error: $ERROR_MSG")
    fi
fi

rm -f "$TEMP_OUTPUT" "$TEMP_ERROR"

# Build JSON output
AVAILABLE_JSON="["
FIRST=true
for pkg in "${AVAILABLE_PKGS[@]}"; do
    $FIRST || AVAILABLE_JSON+=", "
    FIRST=false
    pkg_escaped=$(echo "$pkg" | sed 's/"/\\"/g')
    AVAILABLE_JSON+="\"$pkg_escaped\""
done
AVAILABLE_JSON+="]"

MISSING_JSON="["
FIRST=true
for pkg in "${MISSING_PKGS[@]}"; do
    $FIRST || MISSING_JSON+=", "
    FIRST=false
    pkg_escaped=$(echo "$pkg" | sed 's/"/\\"/g')
    MISSING_JSON+="\"$pkg_escaped\""
done
MISSING_JSON+="]"

cat <<OUTPUT
{
  "status": "$STATUS",
  "available_pkgs": $AVAILABLE_JSON,
  "missing_pkgs": $MISSING_JSON,
  "raw_build_depends": $RAW_JSON
}
OUTPUT