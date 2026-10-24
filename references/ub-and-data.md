# 未定义行为、整数、字符串与内存

> C 不是"随便跑跑就行"的语言：编译器有权在 UB 上做任何事（包括删掉你的边界检查）。下面每条都是能变成线上事故的真事。

## 1. UB 清单（按"出现在真实代码里的频率"排序）

| # | UB | 典型写法 | 正确做法 |
| --- | --- | --- | --- |
| 1 | 有符号整数溢出 | `int i = INT_MAX; i + 1` | 先判范围，或用无符号做模运算 |
| 2 | 数组越界（含 off-by-one） | `buf[len] = 0` 而 `buf` 只有 `len` 字节 | 分配 `len + 1`，或拒绝写入 |
| 3 | 读未初始化内存 | `char buf[64]; send(fd, buf, 64, 0)` | 用 `= {0}` 或 `calloc` |
| 4 | 释放后使用 / 双重释放 | `free(p); ... p->x` | 释放后立刻 `p = NULL`；所有权显式 |
| 5 | 空指针解引用（含 `strlen(NULL)`） | 未检查 `malloc` 返回 | 每个解引用前有非空保证 |
| 6 | `realloc` 失败丢原指针 | `p = realloc(p, n)` | `tmp = realloc(p, n); if (!tmp) …` |
| 7 | 有符号左移负数 / 移位超宽 | `1 << 31`、`1 << n` 且 `n >= 31` | 用 `1u`/`UINT32_C`，并判 `n < 32` |
| 8 | 指针算术越界（即使不解引用） | `p + n` 越出同一对象 | 只在 `[base, base+len]` 内算 |
| 9 | 违反严格别名（strict aliasing） | `*(int*)&f`、把 `char*` 强转 `struct*` | `memcpy` 复制，或 union（C 中允许双关，C++ 不允许） |
| 10 | 未对齐访问 | 从字节缓冲强转 `uint32_t*` 解引用 | `memcpy` 到对齐变量；或用 packed 属性并接受代价 |
| 11 | 修改字符串字面量 | `char *s = "abc"; s[0] = 'x'` | `const char *`（`-Wwrite-strings` 抓） |
| 12 | `memcpy` 重叠 | `memcpy(dst, dst+1, n)` | `memmove` |
| 13 | 格式串与实参不匹配 | `%d` 传 `size_t`、`%s` 传非字符串 | `-Wformat=2` 全抓 |
| 14 | 序列点缺失 | `a[i] = i++`、`f(i++, i++)` | 拆成两条语句 |
| 15 | 除以零 / `INT_MIN / -1` | 用户输入当分母 | 显式判 |
| 16 | 越界索引负数 | `arr[-1]`、`s[len - 1]` 当 `len == 0` | 先判 `len > 0` |
| 17 | `printf("%s", NULL)` | 空字符串指针 | `p ? p : "(null)"` |
| 18 | 位域跨类型/实现定义 | 依赖位域布局做二进制协议 | 显式掩码 + 移位 |
| 19 | `longjmp` 跳过清理 | — | 不要用 `longjmp` 做错误处理 |
| 20 | 用 `%n` / 无界 `scanf("%s")` | 用户输入 | 禁 `%n`；`scanf` 用宽度限定或改 `fgets` |

## 2. 整数：规则与安全写法

### 2.1 必须记住的两条规则

1. **整型提升**：比 `int` 窄的类型（`char`、`short`、`bool`、位域）在算术中先提升为 `int`。所以 `uint8_t a = 200, b = 100; a + b` 是 `300`（int），不是 44。
2. **通常算术转换**：一侧无符号、一侧有符号且宽度相同 → **有符号变为无符号**。于是 `-1 < 1u` 是 **假**：

```c
int n = -1;
if (n < sizeof(buf)) { /* 永远不成立！n 被转成巨大的 size_t */ }
```

安全写法：**先把可能为负的量判掉，再比较**：

```c
if (n < 0) return ERR;
if ((size_t)n < sizeof(buf)) { ... }
```

### 2.2 尺寸类型选择表

| 语义 | 类型 | 反例 |
| --- | --- | --- |
| 字节长度/容量/下标 | `size_t` | `int len = strlen(s)` |
| 指针差 | `ptrdiff_t` | `int` |
| 可能为负的偏移 | `int64_t` 或 `ptrdiff_t` | `unsigned` |
| 有确定宽度的协议字段 | `uint32_t`/`int64_t` | `int`/`long` |
| 位运算掩码 | `uint32_t`/`uint64_t` + `UINT32_C()` 后缀 | `1 << 31` |

### 2.3 溢出检查（不要靠"应该不会"）

```c
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <limits.h>

static bool add_overflow_size(size_t a, size_t b, size_t *out)
{
    if (a > SIZE_MAX - b) return true;
    *out = a + b;
    return false;
}

static bool mul_overflow_size(size_t a, size_t b, size_t *out)
{
    if (a != 0 && b > SIZE_MAX / a) return true;
    *out = a * b;
    return false;
}

/* 分配 n 个 elem 的大小，先判乘法溢出 */
static void *alloc_array(size_t n, size_t elem)
{
    size_t bytes;
    if (mul_overflow_size(n, elem, &bytes)) return NULL;
    return malloc(bytes);
}
```

GCC/Clang 还有内建：`__builtin_add_overflow(a, b, &r)`（更优，但 MSVC 没有）。可移植做法就是上面的手写检查。

## 3. 字符串与缓冲

### 3.1 函数白名单

| 用 | 不用 | 原因 |
| --- | --- | --- |
| `snprintf(dst, cap, fmt, ...)` | `sprintf` / `vsprintf` | 无界 |
| `memcpy`（长度已校验、不重叠） | `strcpy` / `strcat` | 无界 |
| `memmove`（可能重叠） | `bcopy` | |
| `fgets(buf, cap, fp)` / `getline` | `gets` | 无界 |
| `strtok_r` / `strtok_s`（Windows） | `strtok` | 内部静态状态，不可重入 |
| `strnlen`（POSIX/Windows 均有）/ 自写 | `strlen` 在未验证 NUL 的缓冲上 | 可能读越界 |
| `strdup`（POSIX）/ `_strdup`（MSVC） | 手写 `malloc+strcpy` | |

### 3.2 `snprintf` 的返回值必判

```c
int n = snprintf(dst, cap, "%s/%s", dir, name);
if (n < 0) return ERR_FMT;              /* 格式化失败 */
if ((size_t)n >= cap) return ERR_TRUNC; /* 截断：n 是"原本需要"的长度 */
```

注意 `cap == 0` 时 `snprintf` 不写任何字节但仍返回所需长度——这正好可以用来**测量长度**：

```c
int need = snprintf(NULL, 0, "%d bytes", v);
if (need < 0) return ERR;
char *s = malloc((size_t)need + 1u);
if (s == NULL) return ERR_NOMEM;
(void)snprintf(s, (size_t)need + 1u, "%d bytes", v);
```

### 3.3 `strncpy`/`strncat` 的坑（宁可不用）

- `strncpy(dst, src, n)` **不一定**以 NUL 结尾（`src` 长于 `n` 时）。
- `strncat(dst, src, n)` 的 `n` 是"最多复制几个字符"，不是目标剩余容量。
- 结论：用 `snprintf` 或自写 `copy_cstr(dst, cap, src)`：

```c
/* 总是以 NUL 结尾；返回 0 成功，-1 表示截断 */
static int copy_cstr(char *dst, size_t cap, const char *src)
{
    size_t n;
    if (dst == NULL || cap == 0) return -1;
    if (src == NULL) { dst[0] = '\0'; return 0; }
    n = strlen(src);
    if (n >= cap) {
        memcpy(dst, src, cap - 1u);
        dst[cap - 1u] = '\0';
        return -1;
    }
    memcpy(dst, src, n + 1u);
    return 0;
}
```

## 4. 内存所有权

四种形态，**在头文件里写明是哪一种**：

| 形态 | 说明 | 例子 |
| --- | --- | --- |
| 调用方拥有 | 函数内分配、返回给调用方释放 | `char *make_name(void)` |
| 接管所有权 | 传进函数后由被调用方负责释放 | `void buf_free(char *p)` |
| 借用 | 只读/只在调用期间有效 | `int log_msg(const char *msg)` |
| 共享引用计数 | 需要明确 `retain`/`release` | `doc_t *doc_retain(doc_t *)` |

规则：
- `free(NULL)` 合法；`fclose(NULL)` 不合法。**销毁函数都要接受 NULL** 并直接返回（方便 cleanup 路径）。
- 释放后立刻置 NULL（对可写的句柄变量）。
- 结构体里"拥有"的指针要在 `_destroy()` 里统一释放；不要在有栈上拷贝 `struct` 后再释放两次。
- `calloc` 优先于 `malloc + memset`（避免忘记）；但注意 `calloc` 对全零位不代表"有效的 double/指针"以外的语义（现代平台两者都成立）。
- 禁用 `alloca`（不可移植、无溢出检查 → `-Walloca` 可拦）。
- 灵活数组成员 `struct { size_t n; char data[]; }` 只能用 `malloc(sizeof(*p) + n)`，不要 `sizeof` 整结构。

## 5. 失败报告：`errno`

```c
#include <errno.h>
#include <string.h>

errno = 0;
FILE *fp = fopen(path, "rb");
if (fp == NULL) {
    int e = errno;                       /* 立刻保存：后续调用会覆盖 errno */
    fprintf(stderr, "fopen(%s): %s\n", path, strerror(e));
    return -e;
}
```

要点：
- **只有失败时** errno 才有意义（成功不清零）。
- 调用后**立刻**取，中间不要插入任何库调用。
- 线程安全：`strerror` 不保证可重入 → POSIX 用 `strerror_r`，Windows 用 `strerror_s`，或干脆自己 `snprintf("%d", e)` 记错误码。
- `-1` 返回值 + errno 只对"真的是系统调用失败"的函数成立；自己写的函数用自定错误码。

## 6. I/O 循环（短读短写是常态，不是异常）

```c
#include <stddef.h>
#include <stdint.h>
#include <errno.h>

/* POSIX：返回已写字节数，<0 为错误（-EIO 等）。处理 EINTR 与部分写。 */
static int64_t write_all(int fd, const void *buf, size_t len)
{
    const unsigned char *p = (const unsigned char *)buf;
    size_t done = 0;
    while (done < len) {
        ssize_t n = write(fd, p + done, len - done);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -(int64_t)errno;
        }
        if (n == 0) return -(int64_t)EIO;      /* 无法继续，但也不是错误码 0 */
        done += (size_t)n;
    }
    return (int64_t)done;
}
```

读端同理。`fread`/`fwrite` 的返回值语义是"元素个数"，必须配合 `ferror`/`feof` 才能区分"EOF"与"错误"：

```c
size_t n = fread(buf, 1, cap, fp);
if (n < cap) {
    if (ferror(fp)) { /* 真错误 */ }
    else            { /* 读到 EOF，n 是实际长度 */ }
}
```

## 7. 二进制格式与序列化

- **永远不要**把 `struct` 的字节直接写文件/发网络：padding、对齐、`long` 宽度、字节序、`bool` 大小都不保证。
- 正确做法：逐字段用定宽类型 + 显式字节序写：

```c
static void put_u32le(unsigned char out[4], uint32_t v)
{
    out[0] = (unsigned char)(v & 0xFFu);
    out[1] = (unsigned char)((v >> 8) & 0xFFu);
    out[2] = (unsigned char)((v >> 16) & 0xFFu);
    out[3] = (unsigned char)((v >> 24) & 0xFFu);
}

static uint32_t get_u32le(const unsigned char in[4])
{
    return (uint32_t)in[0] | ((uint32_t)in[1] << 8) |
           ((uint32_t)in[2] << 16) | ((uint32_t)in[3] << 24);
}
```

- 文件头固定 magic + version + 显式长度字段；读入时**先校验长度**再分配。
- `#pragma pack(1)` 只用于确实需要紧凑的磁盘/协议结构，且必须配 `_Static_assert(sizeof == N)`；别用它"解决"对齐问题。

## 8. 数值与时间

- 字符串转数：`strtol/strtoll/strtoul` 全家 + **同时检查 `errno`、`endptr`、范围**：

```c
char *end = NULL;
errno = 0;
long v = strtol(s, &end, 10);
if (end == s || *end != '\0' || errno == ERANGE) return ERR_PARSE;
```

- 时间差用**单调时钟**（`clock_gettime(CLOCK_MONOTONIC)` / `QueryPerformanceCounter`）；墙钟会因 NTP 回拨而得到负数。
- 浮点：不要用 `==` 比较计算结果；金额/计数用整数（分/微秒）；`-Wdouble-promotion` 会抓 `float` 被隐式提升的意外。

## 9. 汇编级自查：编译期断言

```c
#include <assert.h>
#include <stddef.h>

_Static_assert(sizeof(int64_t) == 8, "int64_t must be 8 bytes");
_Static_assert(sizeof(void *) == 8, "this build assumes 64-bit");
_Static_assert(offsetof(struct header, len) == 4, "wire format changed");

/* 头文件里声明"导出的布局"，实现里断言，跨编译单元双重保险 */
typedef struct { uint32_t magic; uint32_t version; uint64_t len; } wire_hdr_t;
_Static_assert(sizeof(wire_hdr_t) == 16, "wire_hdr_t must stay 16 bytes");
```

加上 `-Wpadded`（GCC）可发现意外的填充，只在结构体敏感处开启即可，全项目开会太吵。
