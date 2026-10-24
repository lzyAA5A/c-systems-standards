/*
 * demo/module.c —— 实现样例：溢出检查、单一出口清理、截断检测、显式类型。
 * 这份文件应当能在严格档下零警告通过（check-c.ps1 / check-c.sh）。
 */
#include <demo/module.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DEMO_INIT_CAP ((size_t)64)
#define DEMO_MAX_CAP  ((size_t)1 << 30)   /* 1 GiB 上限：拒绝荒唐请求 */

struct demo_buf {
    unsigned char *data;
    size_t         len;
    size_t         cap;
};

/* ---- 内部工具：static，不进头文件 ---- */

static int size_add_overflow(size_t a, size_t b, size_t *out)
{
    if (a > SIZE_MAX - b) {
        return 1;
    }
    *out = a + b;
    return 0;
}

static int demo_reserve(demo_buf_t *b, size_t need)
{
    size_t cap;
    unsigned char *p;

    if (need <= b->cap) {
        return DEMO_OK;
    }
    if (need > DEMO_MAX_CAP) {
        return DEMO_EINVAL;
    }

    cap = (b->cap == 0u) ? DEMO_INIT_CAP : b->cap;
    while (cap < need) {
        if (cap > DEMO_MAX_CAP / 2u) {
            cap = DEMO_MAX_CAP;
            break;
        }
        cap *= 2u;
    }
    if (cap < need) {
        return DEMO_EINVAL;
    }

    p = (unsigned char *)realloc(b->data, cap);
    if (p == NULL) {
        return DEMO_ENOMEM;      /* 原指针仍然有效，b->data 未被覆盖 */
    }
    b->data = p;
    b->cap = cap;
    return DEMO_OK;
}

/* ---- 公开接口 ---- */

demo_buf_t *demo_buf_new(size_t initial_cap)
{
    demo_buf_t *b;
    size_t cap = (initial_cap == 0u) ? DEMO_INIT_CAP : initial_cap;

    if (cap > DEMO_MAX_CAP) {
        return NULL;
    }
    b = (demo_buf_t *)calloc(1u, sizeof *b);
    if (b == NULL) {
        return NULL;
    }
    b->data = (unsigned char *)malloc(cap);
    if (b->data == NULL) {
        free(b);
        return NULL;
    }
    b->cap = cap;
    b->len = 0u;
    return b;
}

void demo_buf_destroy(demo_buf_t *b)
{
    if (b == NULL) {
        return;
    }
    free(b->data);
    b->data = NULL;
    b->len = 0u;
    b->cap = 0u;
    free(b);
}

int demo_buf_append(demo_buf_t *b, const void *data, size_t len)
{
    int rc;
    size_t need;

    if (b == NULL) {
        return DEMO_EINVAL;
    }
    if (len == 0u) {
        return DEMO_OK;            /* 追加 0 字节是合法空操作 */
    }
    if (data == NULL) {
        return DEMO_EINVAL;
    }
    if (size_add_overflow(b->len, len, &need) != 0) {
        return DEMO_EINVAL;
    }
    rc = demo_reserve(b, need);
    if (rc != DEMO_OK) {
        return rc;
    }
    memcpy(b->data + b->len, data, len);
    b->len = need;
    return DEMO_OK;
}

int demo_buf_append_cstr(demo_buf_t *b, const char *s)
{
    if (s == NULL) {
        return DEMO_EINVAL;
    }
    return demo_buf_append(b, s, strlen(s));
}

const void *demo_buf_data(const demo_buf_t *b)
{
    if (b == NULL || b->len == 0u) {
        return NULL;
    }
    return b->data;
}

size_t demo_buf_len(const demo_buf_t *b)
{
    return (b == NULL) ? 0u : b->len;
}

int demo_version_string(char *dst, size_t cap, unsigned major, unsigned minor)
{
    int n;

    if (dst == NULL || cap == 0u) {
        return DEMO_EINVAL;
    }
    n = snprintf(dst, cap, "v%u.%u", major, minor);
    if (n < 0) {
        dst[0] = '\0';
        return DEMO_EINVAL;
    }
    if ((size_t)n >= cap) {
        return DEMO_EINVAL;        /* 截断：dst 仍已 NUL 结尾（snprintf 保证） */
    }
    return DEMO_OK;
}

/* 导出的二进制布局：改了就要升主版本号，这里在编译期拦住 */
typedef struct demo_wire_header {
    uint32_t magic;
    uint32_t version;
    uint64_t payload_len;
} demo_wire_header_t;

_Static_assert(sizeof(demo_wire_header_t) == 16u, "demo wire header ABI changed");
