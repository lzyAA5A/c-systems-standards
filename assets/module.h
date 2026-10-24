/*
 * demo/module.h —— 可增长字节缓冲：这份头文件同时是"规范样例"。
 *
 * 契约要点（每个公开函数都必须能回答这几个问题）：
 *   - 谁分配、谁释放（所有权）
 *   - 参数可不可为 NULL
 *   - 失败时 out 参数是否被改动
 *   - 是否线程安全
 */
#ifndef DEMO_MODULE_H
#define DEMO_MODULE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 错误码：0 成功，负值失败。调用方按值分支，不要依赖 errno。 */
enum {
    DEMO_OK      = 0,
    DEMO_EINVAL  = -1,   /* 参数非法（NULL / 长度 0 / 溢出） */
    DEMO_ENOMEM  = -2,   /* 内存分配失败 */
};

/* 不透明句柄：调用方拿不到布局，ABI 才可控。 */
typedef struct demo_buf demo_buf_t;

/* 创建。成功返回非 NULL；失败返回 NULL（不设置 errno）。
 * 所有权：调用方拥有，必须用 demo_buf_destroy 释放。
 * 线程安全：无（每个实例只能被一个线程使用）。 */
demo_buf_t *demo_buf_new(size_t initial_cap);

/* 销毁。接受 NULL。销毁后句柄不可再用。 */
void demo_buf_destroy(demo_buf_t *b);

/* 追加 len 字节。data 可为 NULL 仅当 len == 0。
 * 不接管 data 的所有权；data 在调用期间必须有效。
 * 失败时缓冲区内容不变。 */
int demo_buf_append(demo_buf_t *b, const void *data, size_t len);

/* 追加 C 字符串（不含结尾 NUL）。 */
int demo_buf_append_cstr(demo_buf_t *b, const char *s);

/* 只读访问。返回的指针在下次 append/destroy 前有效（借用，不要 free）。
 * 空缓冲区返回 NULL。 */
const void *demo_buf_data(const demo_buf_t *b);
size_t      demo_buf_len(const demo_buf_t *b);

/* 写入版本串。返回 DEMO_OK；DEMO_EINVAL 表示参数非法；
 * 内容被截断时返回 DEMO_EINVAL 但 dst 仍是合法的 NUL 结尾字符串。 */
int demo_version_string(char *dst, size_t cap, unsigned major, unsigned minor);

#ifdef __cplusplus
}
#endif
#endif /* DEMO_MODULE_H */
