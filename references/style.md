# 风格、API 设计与模块结构

> 规范的目的不是好看，是让下一个人（或三个月后的你）能在一分钟内判断"这段代码能不能安全调用、出错时发生了什么"。

## 1. 文件与目录布局

```
project/
  include/proj/          公开头文件，命名空间目录（proj/）
    buf.h
  src/                   实现，与头文件同名
    buf.c
    internal.h           模块间私有声明，不进 include/
  tests/
    test_buf.c
  third_party/           SYSTEM 级 include，警告不参与本工程门禁
  CMakeLists.txt
```

规则：
- 一个 `.c` 对应一个同名 `.h`；`.c` 里**先 include 自己的 `.h`**（能立刻暴露头文件不自包含）。
- 头文件只放"别人必须知道的"：不用把内部的 `struct`、辅助宏、`#include <windows.h>` 带出去。
- 不建 `util.c` / `common.c` / `misc.c` 这类万能文件——它们是模块边界腐烂的入口。

## 2. 命名

| 对象 | 约定 | 例 |
| --- | --- | --- |
| 模块前缀 | 小写、与模块同名的短前缀，跨模块统一 | `buf_` |
| 函数 | `模块_动作_对象`，snake_case | `buf_append_bytes` |
| 私有函数 | `static`，同样前缀（便于栈回溯识别） | `static int buf_grow(...)` |
| 类型 | snake_case + `_t` 结尾 | `buf_t`, `buf_iter_t` |
| 枚举值 | `前缀_大写` | `BUF_OK`, `BUF_ERR_FULL` |
| 宏/常量 | 全大写，带前缀 | `BUF_INIT_CAP` |
| 布尔 | `bool`，名字念出来是命题 | `is_open`, `has_owner` |

禁止：单字母名字（除 `i`/`j` 循环和 `p` 指针这种就地小作用域）、拼音、`data`/`info`/`tmp`/`handle` 这类无信息名、`l`（和 `1` 难分）、`count2`。

## 3. 头文件规则

```c
#ifndef PROJ_BUF_H          /* 不用 #pragma once：老 MSVC 与某些构建系统不认 */
#define PROJ_BUF_H

#include <stddef.h>          /* 头文件只包含自己签名需要的头 */
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct buf buf_t;    /* 不透明类型：调用方拿不到布局，ABI 才可控 */

/* 全部函数：返回 0 成功，负值为错误码（见 §5）。
 * 注释必须写清：所有权、可空性、线程安全、失败时 out 参数的状态。 */
int  buf_init(buf_t *b, size_t initial_cap);
void buf_free(buf_t *b);                 /* b 可为 NULL */

/* 追加数据。返回 0 成功；负值为错误。不接管 data 的所有权。 */
int  buf_append(buf_t *b, const void *data, size_t len);

#ifdef __cplusplus
}
#endif
#endif /* PROJ_BUF_H */
```

自查（三条，缺一条就是不规范的头文件）：
1. 单独 `#include` 这个头能编译通过（`gcc -fsyntax-only -include proj/buf.h -x c /dev/null`）。
2. 每个函数都有注释说明"谁释放"和"失败时 out 参数是否被改动"。
3. 没有把内部结构体定义、`<windows.h>`、`<stdio.h>` 之类无关头带进公开面。

## 4. 函数设计

**参数顺序固定**：`(dst, dst_cap, src, src_len)` → `snprintf` 式；`(obj, ...)` → 方法式；出参放最后。

**出参用指针 + 事先置默认值**，失败时明确"是否被改动"：

```c
/* 成功时 *out_len 写入实际长度；失败时 *out_len 不变。 */
int buf_size(const buf_t *b, size_t *out_len);
```

**const 正确性**：只读的指针一律 `const`，`-Wcast-qual` 会替你守住。字符串字面量传 `const char *`（`-Wwrite-strings` 会抓裸 `char *`）。

**返回指针的函数**：只有三种合法形态——① 新分配、调用方拥有；② 借用、不释放、生命周期到下次调用；③ 不返回指针。禁止返回指向可变内部状态的指针。

**合理限制**：函数 ≤ 60 行，嵌套 ≤ 3 层，参数 ≤ 5 个（多余参数用 `struct opts *`）。超了先抽 `static` 辅助函数，不要靠空行分隔"逻辑段落"。

## 5. 错误处理约定

**统一为 int 错误码**（0 成功，负值失败），或"负 errno"：

```c
enum {
    BUF_OK        = 0,
    BUF_EINVAL    = -1,
    BUF_ENOMEM    = -2,
    BUF_EFULL     = -3,   /* 容量上限，语义与 ENOMEM 不同，要分开 */
};
```

- 不要用 `int` 当布尔返回（0/1/其他），也不要用 `-1` 表示所有错误。
- 需要系统错误细节时，配合 `errno` 或自建 `last_error`，但**不要**让 API 同时返回 `-1` 又依赖 `errno` 的"非法组合"。
- 每个错误码都要有一个已知的调用方动作（重试 / 上报 / 退出）。没有动作的错误码是噪声。
- 库代码不 `abort`、不 `exit`、不 `printf` 到 stdout；错误走返回值，日志走注入的回调。

## 6. 单一出口清理模式（唯一推荐写法）

```c
int thing_open(thing_t *t, const char *path)
{
    int rc = THING_EINVAL;
    FILE *fp = NULL;
    char *tmp = NULL;

    if (t == NULL || path == NULL) {
        return THING_EINVAL;
    }
    fp = fopen(path, "rb");
    if (fp == NULL) {
        rc = THING_EIO;
        goto cleanup;
    }
    tmp = malloc(4096);
    if (tmp == NULL) {
        rc = THING_ENOMEM;
        goto cleanup;
    }

    size_t n = fread(tmp, 1, 4096, fp);
    if (n == 0 && ferror(fp)) {   /* 0 可能只是空文件，必须用 ferror 区分 */
        rc = THING_EIO;
        goto cleanup;
    }
    t->f = fp;
    t->buf = tmp;
    fp = NULL;                    /* 所有权移交，cleanup 不再释放 */
    tmp = NULL;
    rc = THING_OK;

cleanup:
    free(tmp);
    if (fp != NULL) {
        (void)fclose(fp);
    }
    return rc;
}
```

要点：初始化 `rc` 为失败值；每个资源句柄先赋"空"，成功后"移交即置 NULL"；label 处逆序释放；绝不在中途裸 `return`。

## 7. 资源获取与释放的成对表

| 获取 | 释放 | 注意 |
| --- | --- | --- |
| `malloc/calloc/realloc` | `free` | realloc 用临时变量 |
| `fopen` | `fclose` | 检查 fclose 返回值（缓冲落盘失败在这报） |
| `open`/`creat` | `close` | 不要和 `closesocket` 混 |
| `fdopen` | `fclose` | 之后不要再 `close(fd)` |
| `pthread_mutex_init` | `pthread_mutex_destroy` | 销毁前确保无线程阻塞其上 |
| `CreateThread` | `CloseHandle` | 线程结束后才关句柄 |
| `LoadLibrary` | `FreeLibrary` | |
| `dlopen` | `dlclose` | |
| `opendir` | `closedir` | |
| `getaddrinfo` | `freeaddrinfo` | |
| `mmap` | `munmap` | |
| `CreateFileMapping` | `UnmapViewOfFile` + `CloseHandle` | 两步都要 |
| `win32 任意 Create*` | `CloseHandle` | 见 diagnostics 的 handle 泄漏检查 |

写新函数时先列这张表的子集，再写代码；漏一项就是泄漏。

## 8. 宏的正确用法

```c
/* 多语句宏必须包 do{}while(0)，参数要加括号，且只求值一次 */
#define PROJ_MAX(a, b) ((a) > (b) ? (a) : (b))       /* 多次求值，仅限无副作用实参 */
#define PROJ_ARRAY_LEN(arr) (sizeof(arr) / sizeof((arr)[0]))

#define PROJ_TRY(expr)                    \
    do {                                  \
        int rc_ = (expr);                 \
        if (rc_ != 0) {                   \
            goto cleanup;                 \
        }                                 \
    } while (0)
```

能用 `static inline` 函数就不要用宏——宏没有类型检查、没有调试信息、会破坏单步调试。宏名里的临时变量加下划线后缀防遮蔽。

## 9. 注释、日志、断言

**注释写"为什么"和"契约"，不写"是什么"**：

```c
/* 允许 cap 之上再追加 1 字节 NUL：调用方常用 snprintf 风格，
 * 这里多留一格避免每个调用点都要 +1。 */
```

**日志**：
- 库代码不直接打印；接收 `void (*log_fn)(int level, const char *msg, void *ud)`。
- 每次失败路径至少一个可定位的日志（函数名 + 关键参数 + 错误码）。
- 不要在日志里打印密码、密钥、完整路径以外的隐私。

**断言**：
- `assert` 只用于"违反就是编程错误"的内部不变量；参数校验用返回值。
- **绝不在 assert 里放副作用**：`assert(init() == 0)` 在 `NDEBUG` 下会让 `init` 从不执行。
- 库的头文件被 include 前可能已定义 `NDEBUG`，所以不要指望 assert 在库内生效；用 `PROJ_CHECK` 自行定义（行为可配置）。

## 10. 模块边界

- 依赖方向单向：`app → domain → os 适配层 → 平台库`。反向依赖只能通过回调/接口。
- 一个模块只能通过头文件暴露的 API 被访问；跨模块直接摸别人的 `struct` 内部字段是设计事故。
- 全局可变状态：默认禁止。确实需要（如分配器、日志器）就显式提供 `xxx_global_init()`/`xxx_global_shutdown()`，并在头文件里声明"非线程安全，需在启动阶段调用"。
- 线程安全要写清楚：`/* 线程安全 */`、`/* 需外部加锁 */`、`/* 单线程 */` 三选一，写在头文件函数注释里。

## 11. 测试的最小要求

每个公开函数至少覆盖：
1. 正常路径；
2. `NULL`/0 长度/超长输入；
3. 失败注入（内存分配失败用可注入分配器，见 diagnostics）；
4. 边界：`cap - 1`、`cap`、`cap + 1` 三种长度。

测试文件独立可执行，返回非 0 表示失败（便于 CI 与脚本判定），不要依赖第三方框架才能跑。
