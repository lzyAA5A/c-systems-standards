#!/usr/bin/env bash
# C 编译门禁（POSIX / MSYS2 / Git-Bash / WSL）
#
# 用法：
#   ./check-c.sh src/                     # 递归编译目录下所有 *.c
#   ./check-c.sh src/a.c src/b.c
#   ./check-c.sh --analyzer src/          # 追加 -fanalyzer（GCC 静态分析，慢）
#   ./check-c.sh --no-werror src/         # 只报警告不失败（存量摸底）
#   ./check-c.sh --cc=clang -I../vendor src/
#
# 退出码：0 全通过；1 有文件失败；2 参数或环境问题。

set -u

CC_BIN="${CC:-gcc}"
USE_ANALYZER=0
USE_WERROR=1
INCLUDES=()
EXTRA=()
TARGETS=()

for arg in "$@"; do
    case "$arg" in
        --analyzer)   USE_ANALYZER=1 ;;
        --no-werror)  USE_WERROR=0 ;;
        --cc=*)       CC_BIN="${arg#--cc=}" ;;
        -I*)          INCLUDES+=("$arg") ;;
        -h|--help)    sed -n '2,12p' "$0"; exit 0 ;;
        -*)           EXTRA+=("$arg") ;;
        *)            TARGETS+=("$arg") ;;
    esac
done

if [ "${#TARGETS[@]}" -eq 0 ]; then
    echo "用法: $0 [--analyzer] [--no-werror] [--cc=gcc] [-I<dir>] <目录|文件.c ...>" >&2
    exit 2
fi

if ! command -v "$CC_BIN" >/dev/null 2>&1; then
    echo "找不到编译器: $CC_BIN" >&2
    exit 2
fi

WARN=(
    -std=c17 -O2 -g
    -Wall -Wextra -Wpedantic
    -Wshadow -Wconversion -Wsign-conversion -Wfloat-conversion
    -Wcast-qual -Wcast-align=strict -Wwrite-strings
    -Wpointer-arith -Wbad-function-cast
    -Wstrict-prototypes -Wmissing-prototypes -Wmissing-declarations
    -Wold-style-definition
    -Wundef -Wvla -Walloca -Walloc-zero -Wdouble-promotion
    -Wformat=2 -Wnull-dereference
    -Wduplicated-cond -Wlogical-op -Wswitch-default
    -Wredundant-decls -Wimplicit-fallthrough
    -fstack-protector-strong
)
[ "$USE_WERROR" -eq 1 ] && WARN+=(-Werror)
[ "$USE_ANALYZER" -eq 1 ] && WARN+=(-fanalyzer)

# 收集源文件
# 注意：用纯 bash 递归，不调 find —— 在 Windows 上从非 MSYS 环境启动时，
# PATH 里的 System32\find.exe 会抢先生效（GNU find 拿不到），导致收集不到文件。
SKIP_DIRS=' build .git out target .cache node_modules third_party '

collect_c_files() {
    local d="$1"
    local f name
    for f in "$d"/*; do
        [ -e "$f" ] || continue
        name="${f##*/}"
        if [ -d "$f" ]; then
            case "$SKIP_DIRS" in
                *" $name "*) continue ;;
                cmake-build-*) continue ;;
            esac
            collect_c_files "$f"
        elif [ "${f##*.}" = "c" ]; then
            FILES+=("$f")
        fi
    done
}

FILES=()
for t in "${TARGETS[@]}"; do
    if [ -d "$t" ]; then
        collect_c_files "$t"
    elif [ -f "$t" ]; then
        FILES+=("$t")
    else
        echo "[skip] 不存在: $t" >&2
    fi
done

if [ "${#FILES[@]}" -eq 0 ]; then
    echo "没有找到 .c 文件。" >&2
    exit 2
fi

WORK="$(mktemp -d 2>/dev/null)"
if [ -z "${WORK:-}" ] || [ ! -d "$WORK" ]; then
    for cand in "${TMPDIR:-}" . /tmp /var/tmp; do
        [ -z "$cand" ] && continue
        if mkdir -p "$cand/cgate.$$" 2>/dev/null && [ -d "$cand/cgate.$$" ]; then
            WORK="$cand/cgate.$$"
            break
        fi
    done
fi
if [ -z "${WORK:-}" ] || [ ! -d "$WORK" ]; then
    echo "无法创建临时目录，请设置 TMPDIR。" >&2
    exit 2
fi
trap 'rm -rf "$WORK"' EXIT

echo "门禁: $CC_BIN  文件数: ${#FILES[@]}  $([ "$USE_ANALYZER" -eq 1 ] && echo '(含静态分析)')"

FAILED=()
i=0
for f in "${FILES[@]}"; do
    i=$((i + 1))
    d="$(dirname "$f")"
    out="$WORK/o$i.o"
    log="$WORK/o$i.log"

    "$CC_BIN" "${WARN[@]}" -I"$d" "${INCLUDES[@]+"${INCLUDES[@]}"}" \
        "${EXTRA[@]+"${EXTRA[@]}"}" -c "$f" -o "$out" >"$log" 2>&1
    rc=$?

    # 过滤掉纯汇编/链接器噪声，只留诊断行
    diag="$(grep -E '(warning|error|note)[: ]|\.c:[0-9]+' "$log" || true)"

    if [ "$rc" -eq 0 ]; then
        printf '\033[32m[PASS] %s\033[0m\n' "$f"
        [ -n "$diag" ] && printf '%s\n' "$diag" | head -40 | sed 's/^/       /'
    else
        printf '\033[31m[FAIL] %s\033[0m\n' "$f"
        printf '%s\n' "$diag" | head -60 | sed 's/^/       /'
        [ -z "$diag" ] && head -20 "$log" | sed 's/^/       /'
        FAILED+=("$f")
    fi
done

echo
if [ "${#FAILED[@]}" -eq 0 ]; then
    printf '\033[32m门禁通过: %d 个文件, 0 错误。\033[0m\n' "${#FILES[@]}"
    exit 0
fi

printf '\033[31m门禁失败: %d/%d 个文件未通过。\033[0m\n' "${#FAILED[@]}" "${#FILES[@]}"
printf '  - %s\n' "${FAILED[@]}"
exit 1
