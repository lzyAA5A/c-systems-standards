#!/usr/bin/env bash
# C / C++ 编译门禁（POSIX / MSYS2 / Git-Bash / WSL）
#
# 用法：
#   ./check-c.sh src/                      # 递归编译目录下所有 .c / .cpp / .cc / .cxx
#   ./check-c.sh src/a.c src/b.cpp
#   ./check-c.sh --analyzer src/           # 追加 -fanalyzer（GCC 静态分析，慢）
#   ./check-c.sh --no-werror src/          # 只报警告不失败（存量摸底）
#   ./check-c.sh --cc=clang --cxx=clang++ src/
#   ./check-c.sh --std=c++23 src/          # 覆盖语言标准（C 与 C++ 分别取匹配的那个）
#
# 退出码：0 全通过；1 有文件失败；2 参数或环境问题。

set -u

CC_BIN="${CC:-gcc}"
CXX_BIN="${CXX:-g++}"
USE_ANALYZER=0
USE_WERROR=1
INCLUDES=()
EXTRA=()
TARGETS=()
STD_C="c17"
STD_CXX="c++20"

for arg in "$@"; do
    case "$arg" in
        --analyzer)   USE_ANALYZER=1 ;;
        --no-werror)  USE_WERROR=0 ;;
        --cc=*)       CC_BIN="${arg#--cc=}" ;;
        --cxx=*)      CXX_BIN="${arg#--cxx=}" ;;
        --std=*)      if [[ "${arg#--std=}" == c++* ]]; then STD_CXX="${arg#--std=}"; else STD_C="${arg#--std=}"; fi ;;
        -I*)          INCLUDES+=("$arg") ;;
        -h|--help)    sed -n '2,13p' "$0"; exit 0 ;;
        -*)           EXTRA+=("$arg") ;;
        *)            TARGETS+=("$arg") ;;
    esac
done

if [ "${#TARGETS[@]}" -eq 0 ]; then
    echo "用法: $0 [--analyzer] [--no-werror] [--cc=gcc] [--cxx=g++] [--std=c++20] [-I<dir>] <目录|源文件...>" >&2
    exit 2
fi

# C 与 C++ 共用的高价值警告
WARN_COMMON=(
    -O2 -g
    -Wall -Wextra -Wpedantic
    -Wshadow -Wconversion -Wsign-conversion -Wfloat-conversion
    -Wcast-qual -Wcast-align=strict -Wwrite-strings
    -Wpointer-arith
    -Wundef -Wvla -Walloca -Walloc-zero -Wdouble-promotion
    -Wformat=2 -Wnull-dereference
    -Wduplicated-cond -Wlogical-op -Wswitch-default
    -Wredundant-decls -Wimplicit-fallthrough
    -fstack-protector-strong
)
# 只有 C 才有的警告（传给 g++ 会直接报错）
WARN_C_ONLY=(
    -Wbad-function-cast
    -Wstrict-prototypes -Wmissing-prototypes -Wmissing-declarations
    -Wold-style-definition
)
# 只有 C++ 才有的警告
WARN_CXX_ONLY=(
    -Wnon-virtual-dtor -Woverloaded-virtual -Wextra-semi
    -Wold-style-cast -Wuseless-cast
)
[ "$USE_WERROR" -eq 1 ] && WARN_TAIL=(-Werror) || WARN_TAIL=()
if [ "$USE_ANALYZER" -eq 1 ]; then WARN_TAIL+=(-fanalyzer); fi

is_cpp() {
    case "${1##*.}" in
        cpp|cc|cxx|c++) return 0 ;;
        *) return 1 ;;
    esac
}
is_c_source() {
    case "${1##*.}" in
        c) return 0 ;;
        *) is_cpp "$1" ;;
    esac
}

# 按需检查编译器存在性（只检查真的会用到的那个）
NEED_CC=0
NEED_CXX=0

# 收集源文件
# 注意：用纯 bash 递归，不调 find —— 在 Windows 上从非 MSYS 环境启动时，
# PATH 里的 System32\find.exe 会抢先生效（GNU find 拿不到），导致收集不到文件。
SKIP_DIRS=' build .git out target .cache node_modules third_party '

collect_sources() {
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
            collect_sources "$f"
        elif is_c_source "$f"; then
            FILES+=("$f")
        fi
    done
}

FILES=()
for t in "${TARGETS[@]}"; do
    if [ -d "$t" ]; then
        collect_sources "$t"
    elif [ -f "$t" ]; then
        FILES+=("$t")
    else
        echo "[skip] 不存在: $t" >&2
    fi
done

if [ "${#FILES[@]}" -eq 0 ]; then
    echo "没有找到 .c / .cpp 文件。" >&2
    exit 2
fi

COUNT_C=0
COUNT_CXX=0
for f in "${FILES[@]}"; do
    if is_cpp "$f"; then COUNT_CXX=$((COUNT_CXX + 1)); NEED_CXX=1
    else COUNT_C=$((COUNT_C + 1)); NEED_CC=1; fi
done

if [ "$NEED_CC" -eq 1 ] && ! command -v "$CC_BIN" >/dev/null 2>&1; then
    echo "找不到 C 编译器: $CC_BIN" >&2
    exit 2
fi
if [ "$NEED_CXX" -eq 1 ] && ! command -v "$CXX_BIN" >/dev/null 2>&1; then
    echo "找不到 C++ 编译器: $CXX_BIN（可用 --cxx= 指定）" >&2
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

echo "门禁: ${CC_BIN}/${CXX_BIN}  C: $COUNT_C  C++: $COUNT_CXX  $([ "$USE_ANALYZER" -eq 1 ] && echo '(含静态分析)')"

FAILED=()
i=0
for f in "${FILES[@]}"; do
    i=$((i + 1))
    d="$(dirname "$f")"
    out="$WORK/o$i.o"
    log="$WORK/o$i.log"

    if is_cpp "$f"; then
        COMPILER="$CXX_BIN"
        WARN=(-std="$STD_CXX" "${WARN_COMMON[@]}" "${WARN_CXX_ONLY[@]}")
        TAG="C++"
    else
        COMPILER="$CC_BIN"
        WARN=(-std="$STD_C" "${WARN_COMMON[@]}" "${WARN_C_ONLY[@]}")
        TAG="C  "
    fi
    if [ "${#WARN_TAIL[@]}" -gt 0 ]; then WARN+=("${WARN_TAIL[@]}"); fi

    "$COMPILER" "${WARN[@]}" -I"$d" "${INCLUDES[@]+"${INCLUDES[@]}"}" \
        "${EXTRA[@]+"${EXTRA[@]}"}" -c "$f" -o "$out" >"$log" 2>&1
    rc=$?

    # 过滤掉纯汇编/链接器噪声，只留诊断行
    diag="$(grep -E '(warning|error|note)[: ]|\.[ch](pp)?:[0-9]+' "$log" || true)"

    if [ "$rc" -eq 0 ]; then
        printf '\033[32m[PASS] [%s] %s\033[0m\n' "$TAG" "$f"
        [ -n "$diag" ] && printf '%s\n' "$diag" | head -40 | sed 's/^/       /'
    else
        printf '\033[31m[FAIL] [%s] %s\033[0m\n' "$TAG" "$f"
        printf '%s\n' "$diag" | head -60 | sed 's/^/       /'
        [ -z "$diag" ] && head -20 "$log" | sed 's/^/       /'
        FAILED+=("$f")
    fi
done

echo
if [ "${#FAILED[@]}" -eq 0 ]; then
    printf '\033[32m门禁通过: %d 个文件（C %d / C++ %d）, 0 错误。\033[0m\n' "${#FILES[@]}" "$COUNT_C" "$COUNT_CXX"
    exit 0
fi

printf '\033[31m门禁失败: %d/%d 个文件未通过。\033[0m\n' "${#FAILED[@]}" "${#FILES[@]}"
printf '  - %s\n' "${FAILED[@]}"
exit 1
