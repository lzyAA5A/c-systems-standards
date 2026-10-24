# Linux ↔ Windows 移植与双平台编程

> 核心结论：**同名 API 的语义差异，比 API 缺失更容易出事**。`rename` 少了两个平台之间的"覆盖目标"假设，就能让一个上线项目丢数据。
> 用法：涉及系统能力的任何新代码，先在本文件查表，把差异收敛到一层 `os_*.c` 适配层。

## 0. 先回答 8 个问题（决定要不要适配层）

1. 这个能力在两边**概念**一致吗？（fd ↔ HANDLE、fork ↔ CreateProcess、signal ↔ 控制台事件：概念不同，别套同名封装）
2. **失败语义**一致吗？（返回 -1 + errno ↔ 返回 FALSE + GetLastError）
3. **数据类型**能对上吗？（`long`、`ssize_t`、`off_t`、`wchar_t`）
4. **编码/换行**会变吗？（UTF-8 ↔ UTF-16/ANSI；`\n` ↔ `\r\n`）
5. **生命周期**一致吗？（Linux 可删已打开文件，Windows 不行）
6. **并发/可重入**一致吗？（`strtok`、`getpwnam`、`localtime` 都不是可重入的）
7. 依赖了哪些**只在一侧存在**的东西？（`/proc`、`epoll`、`io_uring`、`inotify`、注册表、Win32 句柄继承）
8. 有没有**纯标准 C 的替代**？（能不用系统 API 就不用——这是最便宜的跨平台）

## 1. 数据类型：LP64 vs LLP64（最容易致命的一栏）

| 类型 | Linux x86_64 (LP64) | Windows x64 (LLP64) | 结论 |
| --- | --- | --- | --- |
| `long` | **64 位** | **32 位** | 永不用于需要 64 位的地方 |
| `unsigned long` | 64 位 | 32 位 | 同上；`%lu` 跨平台不可靠 |
| `size_t` | 64 位 | 64 位 | 尺寸/长度统一用它 |
| `ptrdiff_t` | 64 位 | 64 位 | 指针差 |
| `intptr_t`/`uintptr_t` | 64 位 | 64 位 | 指针转整数 |
| `ssize_t` | 有 | **不存在** | 用 `ptrdiff_t` 或自定义 |
| `off_t` | 64 位（需 `_FILE_OFFSET_BITS=64`） | **不存在** | Windows 用 `__int64`/`LARGE_INTEGER` |
| `wchar_t` | **32 位 UTF-32** | **16 位 UTF-16** | 不能互相二进制传输 |
| `long double` | x86 上 16 字节（80 位扩展） | **8 字节（等于 double）** | 别靠它提高精度 |
| `time_t` | 64 位 | 64 位（VS2005+ 默认） | 但旧 `_USE_32BIT_TIME_T` 会让它变 32 |
| `char` 符号性 | x86/x64 为 signed | x86/x64 为 signed | **ARM 上不同**（GCC/ARM 默认 unsigned）：要做 UTF-8 解析时统一用 `unsigned char*` |
| 字节序 | 小端 | 小端 | 同架构一致，但**不要**假设；文件/网络格式显式序列化 |

定宽类型只在真正需要宽度时用（协议字段、文件头、哈希、位运算）；不要把所有 `int` 换成 `int32_t` 当风格。

打印格式（跨平台安全的那几个）：

```c
printf("%zu\n", n);            /* size_t，两侧都支持 */
printf("%td\n", d);            /* ptrdiff_t */
printf("%" PRId64 "\n", v);    /* int64_t，需 #include <inttypes.h> */
printf("%" PRIu32 "\n", v);
printf("%p\n", (void *)p);     /* 指针必须转 void* */
```

**不要**用 `%ld`/`%lu` 打印 64 位量、`%d` 打印 `size_t`、`%u` 打印负值——`-Wformat=2` 在两个编译器上都会抓。

## 2. 系统能力对照表

### 2.1 文件与目录

| 能力 | Linux | Windows | 陷阱 |
| --- | --- | --- | --- |
| 句柄类型 | `int fd` | `HANDLE`（`void*`） | 别用 `int` 存 HANDLE |
| 打开 | `open(path, O_RDONLY)` | `CreateFileW(...)` | Windows 必须显式给共享模式 |
| 读写 | `read`/`write` | `ReadFile`/`WriteFile` | 都要处理"短读/短写"循环 |
| 关闭 | `close` | `CloseHandle` | socket 用 `closesocket` |
| 枚举目录 | `opendir`/`readdir` | `FindFirstFileW`/`FindNextFileW` | Windows 结果含 `.`/`..` 也要自己过滤 |
| 获取属性 | `stat` | `GetFileAttributesExW` | `struct stat` 字段不通用 |
| 删除已打开文件 | 可以（inode 延迟释放） | **失败**（共享冲突） | 需要 `FILE_SHARE_DELETE`，或改用 `FILE_FLAG_DELETE_ON_CLOSE` |
| 重命名覆盖 | `rename` 可覆盖已存在目标 | `rename` 目标存在**报错** | 用 `MoveFileExW(..., MOVEFILE_REPLACE_EXISTING)` |
| 临时文件 | `mkstemp`（安全） | `GetTempFileNameW`（旧）/ `GetTempPath2W`+`CreateFileW` | Windows 的 `tmpnam` 不可靠 |
| 绝对路径 | `realpath` | `GetFullPathNameW` / `GetFinalPathNameByHandleW` | |
| 符号链接 | `symlink` | `CreateSymbolicLinkW`（需要权限或开发者模式） | 别把符号链接当可移植特性 |
| 文件锁 | `flock` / `fcntl(F_SETLK)` | `LockFileEx` | 语义（建议锁/强制锁）不同，跨平台锁要单独设计 |
| 刷盘 | `fsync`/`fdatasync`（目录也要 fsync） | `FlushFileBuffers` | 目录 fsync 在 Windows 无对应 |
| 内存映射 | `mmap`/`munmap` | `CreateFileMappingW`+`MapViewOfFile`/`UnmapViewOfFile`+`CloseHandle` | Windows 要释放两次 |
| 文件变更通知 | `inotify`/`epoll` | `ReadDirectoryChangesW` | 抽象成本高，通常单独实现 |
| 空设备 | `/dev/null` | `"NUL"` | 硬编码路径必错 |
| 路径分隔符 | `/` | `\`（API 也大多接受 `/`） | 只在**显示**和**解析**上处理，别到处 `str_replace` |
| 大小写 | 敏感 | 不敏感但保留大小写 | 文件名当 key 时必须规范化 |
| 长度上限 | 4096（`PATH_MAX`） | **260（MAX_PATH）**，除非 `\\?\` 前缀或启用了长路径 | 深目录/中文长名项目必踩 |

### 2.2 编码、路径与终端（中文项目 90% 的"乱码"来源）

| 项 | Linux | Windows |
| --- | --- | --- |
| 原生字符串 | UTF-8（字节流，无内建校验） | **UTF-16**（所有 `*W` API） |
| 窄字符 API | 就是 UTF-8 | `*A` = 系统 ANSI 代码页（中文机为 **GBK/cp936**） |
| 源文件编码 | 基本 UTF-8 | **必须 `/utf-8` 或 `/source-charset:utf-8`**，否则 MSVC 按本地代码页解析 |
| 控制台输出 | UTF-8 直出 | 默认 GBK；要 UTF-8 需 `SetConsoleOutputCP(CP_UTF8)`（+ `_setmode(_fileno(stdout), _O_U8TEXT)` 或改用 `WriteConsoleW`）|
| 命令行参数 | `argv` 是 UTF-8 字节 | `main` 的 `argv` 是 **ANSI**；要正确中文用 `wmain(int, wchar_t**)` 或 `GetCommandLineW` |
| 打开中文路径 | `fopen(path_utf8)` | `fopen` 走 ANSI → **中文路径可能打不开**；用 `_wfopen` + `MultiByteToWideChar(CP_UTF8)` |
| 换行 | `\n` | 文本模式写 `\n` → 落盘 `\r\n`；读时反向转换 |
| 终端判断 | `isatty(fd)` | `_isatty(_fileno(stdout))` 或 `GetConsoleMode` 成功 |
| ANSI 颜色 | 直接写 `\x1b[...m` | Win10+ 需先 `SetConsoleMode(ENABLE_VIRTUAL_TERMINAL_PROCESSING)` |

三条硬规矩：
1. **文件内容一律 UTF-8**，二进制标志 `"rb"/"wb"` 显式写。
2. **Windows 侧 UTF-8 → UTF-16 转换集中到一个函数**，不要在每个调用点写 `MultiByteToWideChar`。
3. 源文件里**不要**写依赖代码页的字面量；中文提示语用 UTF-8 源文件 + `/utf-8`。

```c
/* 只有这一层知道 Windows 的宽窄转换 */
#if defined(_WIN32)
#include <windows.h>
static wchar_t *utf8_to_wide(const char *s)          /* 返回需 free；失败返回 NULL */
{
    if (s == NULL) return NULL;
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, NULL, 0);
    if (n <= 0) return NULL;
    wchar_t *w = malloc((size_t)n * sizeof *w);
    if (w == NULL) return NULL;
    if (MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n) <= 0) { free(w); return NULL; }
    return w;
}
#endif
```

### 2.3 线程与同步

| 能力 | Linux | Windows | 备注 |
| --- | --- | --- | --- |
| 标准做法 | `pthread_*` 或 **C11 `<threads.h>`** | MSVC **不支持** `<threads.h>` | 真正可移植：`pthread` / Win32 各写一份，或引第三方库 |
| 建线程 | `pthread_create` | `_beginthreadex`（**不要**直接用 `CreateThread`：CRT 的 errno/strerror 需要 TLS 初始化） | |
| 互斥 | `pthread_mutex_t` | `SRWLOCK`（最快）/ `CRITICAL_SECTION` | 自己实现时封装成 `mutex_t` |
| 条件变量 | `pthread_cond_t` | `CONDITION_VARIABLE` | 都要求 while 循环包 wait 防虚假唤醒 |
| 一次性初始化 | `pthread_once` | `INIT_ONCE` | |
| 线程局部 | `_Thread_local`（C11）/ `__thread` | `_Thread_local`（MSVC 2019+ 支持）/ `__declspec(thread)` | **DLL 里的 `__declspec(thread)` 动态加载会炸** |
| 原子 | `<stdatomic.h>`（C11） | **MSVC 长期不支持**（VS2022 17.5+ 才有 `stdatomic.h` 部分支持） | 跨平台原子需自己写或引库 |
| 读写下 | `pthread_rwlock` | `SRWLOCK` 的共享/独占 | |

线程安全的必要声明（写在头文件）：`/* 线程安全 */` / `/* 需外部加锁 */` / `/* 仅单线程 */`。不写等于没设计。

### 2.4 进程、信号、动态加载

| 能力 | Linux | Windows |
| --- | --- | --- |
| 创建进程 | `fork` + `execve` | `CreateProcessW`（**没有 fork**；`spawn` 家族可近似） |
| 等待/退出码 | `waitpid` + `WIFEXITED` | `WaitForSingleObject` + `GetExitCodeProcess` |
| 管道 | `pipe`（+ `dup2` 重定向） | `CreatePipe`（句柄需可继承） |
| Ctrl+C | `sigaction(SIGINT)` | `SetConsoleCtrlHandler`（`CTRL_C_EVENT`/`CTRL_CLOSE_EVENT`） |
| 终止信号 | `SIGTERM` | **没有**；控制台关闭走 `CTRL_CLOSE_EVENT`；服务用 SCM |
| 写已关闭的 socket | `SIGPIPE`（不处理就杀进程）→ 必须 `signal(SIGPIPE, SIG_IGN)` 或用 `MSG_NOSIGNAL` | 无此信号，`send` 返回错误码 |
| 崩溃捕获 | `signal(SIGSEGV)`（**不安全**，只能做最小动作） | `SetUnhandledExceptionFilter` / `AddVectoredExceptionHandler` |
| 崩溃转储 | core dump（`ulimit -c`、`core_pattern`） | WER `LocalDumps` 注册表 / `MiniDumpWriteDump` |
| 动态加载 | `dlopen`/`dlsym`/`dlclose` | `LoadLibraryW`/`GetProcAddress`/`FreeLibrary` |
| 环境变量 | `getenv`/`setenv`（UTF-8） | `GetEnvironmentVariableW`（UTF-16）；`getenv` 是 ANSI |
| 用户目录 | `$HOME` | `SHGetKnownFolderPath(FOLDERID_Profile)` |
| 服务/守护 | systemd unit、`fork` 双次 | Windows 服务（SCM）、任务计划 |

### 2.5 网络

| 项 | Linux | Windows |
| --- | --- | --- |
| 初始化 | 无 | **必须** `WSAStartup()` 一次，退出前 `WSACleanup()` |
| socket 类型 | `int` | `SOCKET`（`UINT_PTR`，可等于 INVALID_SOCKET） |
| 关闭 | `close` | `closesocket` |
| 错误码 | `errno` / `EAGAIN` | `WSAGetLastError()` / `WSAEWOULDBLOCK` |
| 非阻塞 | `fcntl(O_NONBLOCK)` | `ioctlsocket(FIONBIO)` |
| 事件等待 | `epoll`/`poll` | `WSAPoll`（Win10+ 较稳）/ **IOCP**（高性能首选） |
| `select` | 无硬性上限 | `FD_SETSIZE` 默认 **64**，需 `#define FD_SETSIZE` 前置放大 |
| 地址结构 | `sockaddr_in` | 同名但用 `InetPtonA/W`、`getaddrinfo` 可移植 |
| 可移植写法 | `getaddrinfo` + `send`/`recv` 循环处理部分收发 | 同左 |

网络代码的正确性门槛：**必须处理短读短写、`EINTR`/`WSAEINTR`、以及"对端优雅关闭"**（`recv` 返回 0 是关闭，不是错误）。

## 3. CRT 与 DLL 边界（Windows 独有的致命坑）

- **每个模块（exe / 每个 DLL）可能各有一份 CRT 堆**：在 DLL 里 `malloc`、在 exe 里 `free` → 堆损坏或崩溃。
- 规则：**谁分配谁释放**。跨模块接口要么提供 `xxx_free()` 配套函数，要么要求共享同一 CRT（`/MD`）。
- `/MT`（静态 CRT）会让每个模块真的独立——适合单 exe，不适合多 DLL 共享对象。
- 运行时统一：**同一进程里别混 `/MT` 与 `/MD`**。
- 调试堆：`_CrtCheckMemory()`、`_CrtSetDbgFlag(_CRTDBG_LEAK_CHECK_DF)` 在 Debug 版可查泄漏（见 diagnostics）。
- 跨 ABI 的结构体：即使同平台同编译器，`#pragma pack`、对齐、`bool` 大小在不同编译器组合同样会变。导出结构体必须 `_Static_assert(sizeof(X) == N, "ABI")`。

## 4. 适配层建议（把差异拦在这里）

建议只在这 12 个原语上加 `#ifdef`，业务代码零 `#ifdef`：

```c
/* os.h —— 唯一允许出现平台分支的边界 */
int      os_time_monotonic_ns(int64_t *out_ns);      /* 只用于算间隔 */
int      os_time_wall_ns(int64_t *out_ns);           /* 墙钟，可回拨 */
void     os_sleep_ms(unsigned ms);
uint64_t os_thread_id(void);
int      os_mutex_init(os_mutex_t *m);
int      os_mutex_lock(os_mutex_t *m);
int      os_mutex_unlock(os_mutex_t *m);
int      os_env_get(const char *name, char *buf, size_t cap);   /* UTF-8 in/out */
int      os_path_join(char *dst, size_t cap, const char *a, const char *b);
int      os_path_is_absolute(const char *path);                 /* 返回 1/0/-1 */
int      os_file_read_all(const char *path, void **out, size_t *out_len);  /* 内部用 "rb" */
int      os_temp_dir(char *dst, size_t cap);
```

约定：
- 全部 UTF-8 进出，Windows 实现内部转 UTF-16。
- 全部返回 `int`（0/负错误码），不泄露 `HANDLE`/`fd` 到上层。
- 平台差异（睡眠精度、单调时钟源、路径上限）**写进注释**，让上层知道哪些保证不成立。
- 单测在两侧都跑一遍（Linux 侧用 WSL 或 CI；本机可先验 Windows 侧）。

## 5. 移植检查表（改完自查）

- [ ] 没有 `int`/`long` 装 64 位量；打印格式全部 `%zu`/`PRI*`
- [ ] 所有文件打开都有显式 `"b"`；文本处理显式处理 `\r\n`
- [ ] 路径拼接不用硬编码 `/` 或 `\`；长路径有 `\\?\` 或已声明限制
- [ ] Windows 侧所有路径/命令行/环境变量都经过 UTF-8↔UTF-16 转换
- [ ] `rename`/删除/临时文件的语义差异已处理
- [ ] socket 有 `WSAStartup`、`closesocket`、短读短写循环
- [ ] 无 `fork`、无 `SIGPIPE` 依赖、`SIGTERM` 处理有 Windows 等价物
- [ ] 跨 DLL 的内存分配/释放配对了
- [ ] 导出的结构体有 `_Static_assert(sizeof)` 与对齐断言
- [ ] `#ifdef _WIN32` 只出现在 `os_*.c`
