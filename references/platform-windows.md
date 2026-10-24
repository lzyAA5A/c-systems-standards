# Windows 专属机制：Win32 系统编程需要知道的那些"Windows 才有"的东西

这份文件专讲 **Windows 特有的概念、API 与行为陷阱**。
POSIX ↔ Win32 的逐项对照在 `portability.md`；这里讲的是"为什么 Windows 长这样"和"用错了会怎么死"。

---

## 一、心智模型：四个基础事实

1. **内核对象 + 句柄**。`HANDLE` 不是文件描述符，是**内核对象表里的索引**。进程、线程、文件、事件、互斥量、socket 之外的一切都是内核对象，都有句柄和引用计数。
2. **两套 API 并存**。`kernel32/user32/advapi32/ws2_32` 是表面，底下是 `ntdll` 的 NT 原生 API。日常只用前者。
3. **字符串是 UTF-16**。所有 Win32 API 都有 `...A`（ANSI，实际是本地代码页）和 `...W`（宽字符）两个版本，`UNICODE` 宏决定 `MessageBox` 展开成哪个。
4. **错误码是线程局部的**。`GetLastError()` 返回当前线程上一次失败的值，**必须在失败后立刻取**，中间任何 API 调用都可能覆盖它。

---

## 二、字符集：Windows 上最容易翻车的地方

### 铁律：永远用 `...W` 版本

```c
#define UNICODE                 /* 让 TCHAR 系列展开成 W 版 */
#define _UNICODE
#define WIN32_LEAN_AND_MEAN     /* 别把 winsock2.h 和 windows.h 的老 socket 撞上 */
#define NOMINMAX                /* 否则 std::min/max 被宏干掉 */
#include <windows.h>
```

```c
/* ✗ A 版：路径含中文就变 "??"，因为按当前代码页解释 */
CreateFileA("C:\\数据\\a.txt", ...);

/* ✓ W 版：显式宽字符 */
CreateFileW(L"C:\\数据\\a.txt", ...);
```

### 三层字符串的转换关系

| 层 | 类型 | 编码 |
| --- | --- | --- |
| Win32 API | `wchar_t *`（`WCHAR`、`LPWSTR`） | UTF-16LE |
| 控制台 | `char *` | 代码页（中文系统默认 936/GBK） |
| 文件内容 | `char *` | 你用什么都行，但**约定用 UTF-8** |

**跨平台内部统一用 UTF-8 的 `char*`，只在调 Win32 API 的那一层转成 UTF-16**：

```c
/* UTF-8 → UTF-16，调用方负责 free */
static wchar_t *utf8_to_wide(const char *s) {
    if (s == NULL) return NULL;
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (n <= 0) return NULL;
    wchar_t *w = (wchar_t *)malloc((size_t)n * sizeof(wchar_t));
    if (w == NULL) return NULL;
    if (MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n) <= 0) {
        free(w);
        return NULL;
    }
    return w;
}

/* UTF-16 → UTF-8 */
static char *wide_to_utf8(const wchar_t *w) {
    if (w == NULL) return NULL;
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
    if (n <= 0) return NULL;
    char *s = (char *)malloc((size_t)n);
    if (s == NULL) return NULL;
    if (WideCharToMultiByte(CP_UTF8, 0, w, -1, s, n, NULL, NULL) <= 0) {
        free(s);
        return NULL;
    }
    return s;
}
```

**`wchar_t` 在 Windows 是 16 位**（UTF-16 码元），Linux 是 32 位（UTF-32）。
所以 `wcslen` 在 Windows 返回的是**码元数不是字符数**——emoji 占 2 个。

### 控制台输出的中文乱码

```c
SetConsoleOutputCP(CP_UTF8);     /* 让控制台按 UTF-8 解释输出字节 */
SetConsoleCP(CP_UTF8);           /* 输入同理 */
```

但 **`printf` 输出 UTF-8 到 CP_UTF8 控制台仍可能乱码**（老控制台不支持）。
可靠做法是用 `WriteConsoleW` 直接写宽字符，或改用 Windows Terminal。

---

## 三、句柄：与 fd 的本质差别

| 项目 | POSIX fd | Windows HANDLE |
| --- | --- | --- |
| 本质 | 进程内小整数索引 | 内核对象表索引（值可能很大且不连续） |
| 读写 | `read`/`write` | `ReadFile`/`WriteFile` |
| 关闭 | `close` | `CloseHandle`（socket 用 `closesocket`） |
| 无效值 | `-1` | `INVALID_HANDLE_VALUE`（`(HANDLE)-1`）；但 `CreateThread` 等失败返回 `NULL` |
| 继承 | fork 自动继承 | 需在 `SECURITY_ATTRIBUTES.bInheritHandle = TRUE` 时创建 |
| 可等待 | 否 | **是**——几乎所有句柄都能 `WaitForSingleObject` |

**"句柄可等待"是 Windows 的核心设计**：文件读完成、进程退出、事件置位、线程结束，全都是"等一个句柄"。
这让 `WaitForMultipleObjects` 成为 Windows 版的事件循环基础（上限 **64** 个句柄，超了要分批或用 IOCP）。

### 句柄泄漏

```c
/* 每个成功返回的句柄都要 CloseHandle，包括失败路径 */
HANDLE h = CreateFileW(...);
if (h == INVALID_HANDLE_VALUE) return -1;

BOOL ok = ReadFile(h, buf, n, &read, NULL);
CloseHandle(h);              /* 无论 ok 与否都要关 */
if (!ok) return -1;
```

泄漏排查：任务管理器加"句柄数"列，或 Process Explorer 看 `Handles`；
程序内用 `GetProcessHandleCount(GetCurrentProcess(), &n)` 定期打点。

---

## 四、进程与线程

### CreateProcess 的字符串陷阱

```c
STARTUPINFOW si = {0};
si.cb = sizeof si;
PROCESS_INFORMATION pi = {0};

/* lpApplicationName 给 NULL 时，系统会解析 lpCommandLine 找可执行文件 */
/* lpCommandLine 必须可写（API 会原地改它），且含空格的路径要加引号 */
wchar_t cmd[] = L"\"C:\\Program Files\\app\\a.exe\" --flag \"arg with space\"";

if (!CreateProcessW(NULL, cmd, NULL, NULL, FALSE,
                    CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) {
    /* GetLastError() 立刻取 */
}
CloseHandle(pi.hThread);
CloseHandle(pi.hProcess);
```

三个必须知道的点：

1. **参数是一个字符串**，不是 argv 数组。双引号规则是微软特有的（`CommandLineToArgvW` 解析）。
2. 路径里含空格必须加引号；反斜杠在引号前要成对转义（`"C:\a\\"` → 实际是 `C:\a\`）。
3. 想拿退出码必须 `WaitForSingleObject(pi.hProcess, INFINITE)` + `GetExitCodeProcess`。

### 限制子进程：Job Object

Windows 没有 `setrlimit`。限制 CPU/内存/进程数用 Job：

```c
HANDLE job = CreateJobObjectW(NULL, NULL);
JOBOBJECT_EXTENDED_LIMIT_INFORMATION li = {0};
li.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
                                    | JOB_OBJECT_LIMIT_PROCESS_MEMORY;
li.ProcessMemoryLimit = 512ull * 1024 * 1024;
SetInformationJobObject(job, JobObjectExtendedLimitInformation, &li, sizeof li);
AssignProcessToJobObject(job, pi.hProcess);      /* 子进程及其后代都受约束 */
```

`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` 是关闭时自动杀进程树的关键——比手动 `TerminateProcess` 干净。

### 线程：用 `_beginthreadex` 而不是 `CreateThread`

```c
uintptr_t th = _beginthreadex(NULL, 0, thread_fn, arg, 0, NULL);
```

原因：`CreateThread` 不初始化 CRT 的线程局部数据（`errno`、`strtok` 的状态、`localtime` 缓冲）。
用 `CreateThread` + CRT 函数 = 内存泄漏和随机错误。`_beginthreadex` 内部调 `CreateThread` 并包了 CRT 初始化。

> C++ 里没有这个问题——`std::thread` 已经处理了。但**在 DLL 里创建线程**时仍有 CRT 选择问题。

---

## 五、同步原语的选择

| 原语 | 开销 | 可跨进程 | 何时用 |
| --- | --- | --- | --- |
| `CRITICAL_SECTION` | 最低（用户态自旋 + 内核回退） | ❌ | 进程内互斥首选 |
| `SRWLOCK` | 低，支持读写锁 | ❌ | 读多写少 |
| `Mutex` | 高（内核对象） | ✅ 命名后可 | 需要跨进程或需要 `WaitForMultipleObjects` |
| `Semaphore` | 中 | ✅ | 计数信号量 |
| `Event` | 中 | ✅ | 线程/进程间通知，"等某件事发生" |
| 条件变量 | 中 | ❌ | `SleepConditionVariableCS` / `_SRW` |

**常见错误**：用 `Mutex` 做进程内互斥——慢十倍以上。用 `CRITICAL_SECTION` 但要记得 `DeleteCriticalSection`。

`WaitForMultipleObjects` 的两个限制：
- 最多 **64** 个句柄
- `bWaitAll` 模式下**不能有重复句柄**（会返回 `WAIT_FAILED`）

---

## 六、异步 I/O 与完成端口（IOCP）

Windows 的异步模型是**完成通知**，不是 Linux 的就绪通知。

```c
/* 1. 打开时声明要重叠 I/O */
HANDLE f = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL,
                       OPEN_EXISTING, FILE_FLAG_OVERLAPPED, NULL);

/* 2. 每次操作都带一个 OVERLAPPED 结构（它同时是"请求单"和"完成凭据"） */
OVERLAPPED ov = {0};
ov.Offset = 0;
ov.OffsetHigh = 0;
ReadFile(f, buf, n, NULL, &ov);      /* 返回 FALSE + ERROR_IO_PENDING 是正常的 */

/* 3. 用 GetOverlappedResult 或完成端口取结果 */
DWORD got;
GetOverlappedResult(f, &ov, &got, TRUE);
```

**关键约束**：`OVERLAPPED` 结构必须活得比操作久（不能是栈上临时变量），
且同一个 `OVERLAPPED` 在完成前不能被复用。

### IOCP 的模型

```c
HANDLE iocp = CreateIoCompletionPort(INVALID_HANDLE_VALUE, NULL, 0, 0);
CreateIoCompletionPort(fileHandle, iocp, (ULONG_PTR)ctx, 0);   /* 绑定 */

/* 工作线程池里循环取完成事件 */
DWORD bytes; ULONG_PTR key; LPOVERLAPPED pov;
GetQueuedCompletionStatus(iocp, &bytes, &key, &pov, INFINITE);
```

IOCP 的并发控制内建：系统保证同时运行的线程数 ≈ CPU 核数，
**这是 Windows 高并发服务器的标准答案**（nginx for Windows、libuv 的 win 后端都基于它）。

### epoll → IOCP 移植的思维转换

| epoll（就绪） | IOCP（完成） |
| --- | --- |
| "这个 fd 可以读了，你去读" | "你之前那个读操作做完了，结果在这" |
| 事件循环里发起读 | 发起读之后立刻返回，完成时被通知 |
| 状态机在用户态 | 状态机可以在 `OVERLAPPED` 的扩展结构里 |

**不能机械翻译**。就绪模型是"轮询状态"，完成模型是"回调结果"，代码结构得重写。

---

## 七、路径与文件名：Windows 的独特限制

| 规则 | 细节 |
| --- | --- |
| `MAX_PATH` = 260 | 大多数 API 的上限；超过要 `\\?\` 前缀（且路径必须是绝对路径、只能用 `\`） |
| 保留设备名 | `CON` `PRN` `AUX` `NUL` `COM1`~`COM9` `LPT1`~`LPT9`，**任何目录下叫这名字的文件都打不开** |
| 大小写不敏感但保留大小写 | `A.txt` 和 `a.txt` 是同一个文件 |
| 结尾的点和空格被吃掉 | `"a.txt."` 实际是 `"a.txt"` |
| 冒号是 ADS 分隔符 | `file.txt:stream` 是备用数据流，杀毒软件常藏东西的地方 |
| 路径分隔符 | `/` 在多数 API 里也被接受，但**规范化行为不同**，别依赖 |

```c
/* 长路径：\\?\ 前缀 + 绝对路径 + 反斜杠 */
CreateFileW(L"\\\\?\\C:\\very\\long\\path\\...\\file.txt", ...);
```

**判断路径是否合法**不要用黑名单（禁 `\ / : * ? " < > |`），要用 `GetFullPathNameW` 规范化后再判断。

---

## 八、注册表：Windows 的"配置文件"

| 根键 | 用途 |
| --- | --- |
| `HKEY_CURRENT_USER` (HKCU) | 当前用户配置，**优先用这个**（不需要管理员权限） |
| `HKEY_LOCAL_MACHINE` (HKLM) | 全机配置，写需要管理员 |
| `HKEY_CLASSES_ROOT` | 文件关联，是 HKLM\Software\Classes 的合并视图 |

```c
HKEY k;
LSTATUS st = RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\MyApp", 0, KEY_READ, &k);
if (st == ERROR_SUCCESS) {
    DWORD type, size = sizeof(buf);
    RegQueryValueExW(k, L"InstallDir", NULL, &type, (BYTE *)buf, &size);
    RegCloseKey(k);
}
```

**32/64 位注册表重定向**：64 位系统上，32 位程序访问 `HKLM\Software` 会被重定向到
`HKLM\Software\WOW6432Node`。用 `KEY_WOW64_64KEY` / `KEY_WOW64_32KEY` 显式指定视图。

---

## 九、Windows 服务（守护进程的对应物）

```c
SERVICE_TABLE_ENTRYW table[] = {
    { L"MyService", (LPSERVICE_MAIN_FUNCTIONW)service_main },
    { NULL, NULL }
};
StartServiceCtrlDispatcherW(table);      /* 进程入口里调用，会阻塞 */
```

服务必须实现 `SERVICE_STATUS_HANDLE` + 控制处理器，响应 `SERVICE_CONTROL_STOP`。
**调试服务很难**（没有控制台），标准做法是加一个"以前台模式运行"的开关，或挂调试器到 `svchost` 之外的自建宿主。

用 `sc.exe` 安装：

```bat
sc create MyService binPath= "C:\path\svc.exe" start= auto
sc start MyService
```

**注意 `=` 后面必须有空格**（`binPath= "..."`），这是 `sc` 的怪癖。

---

## 十、COM 基础（遇到才需要）

| 概念 | 说明 |
| --- | --- |
| `IUnknown` | 所有 COM 接口的基类，三个方法：`QueryInterface`/`AddRef`/`Release` |
| 引用计数 | `AddRef` 加、`Release` 减，减到 0 自动销毁 |
| `CoInitializeEx` | 线程初始化，`COINIT_APARTMENTTHREADED`（STA）或 `COINIT_MULTITHREADED`（MTA） |
| GUID / IID / CLSID | 接口标识 / 类标识，用 `__uuidof` 或 `IID_xxx` 常量 |
| `CoCreateInstance` | 创建对象 |

```c
CoInitializeEx(NULL, COINIT_MULTITHREADED);
IShellLinkW *link = NULL;
HRESULT hr = CoCreateInstance(&CLSID_ShellLink, NULL, CLSCTX_INPROC_SERVER,
                              &IID_IShellLinkW, (void **)&link);
if (SUCCEEDED(hr)) {
    link->lpVtbl->Release(link);
}
CoUninitialize();
```

**`HRESULT` 判断用 `SUCCEEDED`/`FAILED` 宏**，不要写 `hr == S_OK`（`S_FALSE` 也是成功）。

C++ 里可以用 `Microsoft::WRL::ComPtr`，省掉手写 `Release`。

---

## 十一、内存与堆

| API | 层次 | 用途 |
| --- | --- | --- |
| `HeapAlloc`/`HeapFree` | 堆管理器 | 进程默认堆，小对象 |
| `VirtualAlloc`/`VirtualFree` | 页级 | 大块、需要对齐、需要 `MEM_RESERVE` 预留 |
| `malloc`/`free` | CRT | **跨模块绝对不能混用** |

**堆不能跨模块传递**：在 DLL 里 `malloc`、在主程序里 `free` → 堆破坏。
`/MD`（共享 CRT）能缓解，但版本不一致仍会炸。跨 DLL 传内存，由分配方提供释放函数。

### 内存诊断

```c
/* 只在 Debug 版有效：程序退出时打印泄漏块 */
_CrtSetDbgFlag(_CRTDBG_ALLOC_MEM_DF | _CRTDBG_LEAK_CHECK_DF);
```

大页、NUMA、工作集这些用 `VirtualAlloc2` / `SetProcessWorkingSetSizeEx`，
普通业务代码用不到，知道名字即可。

---

## 十二、异常与崩溃处理

### SEH 与 C++ 异常

```c
__try {
    risky();
} __except (EXCEPTION_EXECUTE_HANDLER) {
    /* 崩溃了，记日志 */
}
```

**不要用 SEH 做常规错误处理**——它捕的是访问违例、除零这类硬件异常，
捕到之后进程状态通常已不可信，正确做法是**记录现场后退出**。

C++ 的 `try/catch` 和 SEH 是两套机制，混用时 MSVC 的 `/EHa` 才会让 `catch(...)` 捕到 SEH，
但那会让析构顺序失控。**保持 `/EHsc`**，SEH 只用在最外层的崩溃兜底。

### 崩溃转储

```c
#include <dbghelp.h>
#pragma comment(lib, "dbghelp.lib")

void write_dump(EXCEPTION_POINTERS *ep, const wchar_t *path) {
    HANDLE f = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
                           FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE) return;
    MINIDUMP_EXCEPTION_INFORMATION info = {GetCurrentThreadId(), ep, FALSE};
    MiniDumpWriteDump(GetCurrentProcess(), GetCurrentProcessId(), f,
                      MiniDumpWithFullMemory, &info, NULL, NULL);
    CloseHandle(f);
}
```

或者不改代码：配置 **WER LocalDumps** 注册表项，让系统在崩溃时自动落 dump。

---

## 十三、诊断工具箱（Windows 侧）

| 症状 | 工具 |
| --- | --- |
| 崩溃 | PDB + WinDbg / Visual Studio 打开 dump，`!analyze -v` |
| 句柄泄漏 | Process Explorer → 句柄列表；`handle.exe` |
| 内存增长 | VMMap、`!heap -s`、Application Verifier |
| 文件被占用 | Process Explorer → Find Handle，或 `handle.exe path` |
| 卡死 | Process Explorer 看线程栈（需符号），`Wait Chain Analysis` |
| 系统调用失败 | Process Monitor（ProcMon）过滤 `Result != SUCCESS` |
| API 用错 | Application Verifier（堆、句柄、锁的运行时校验） |
| 网络问题 | Wireshark + `netstat -ano` + `Get-NetTCPConnection` |

**符号很重要**：设置 `_NT_SYMBOL_PATH=srv*C:\symbols*https://msdl.microsoft.com/download/symbols`
才能把栈解析成函数名。

---

## 十四、Windows 侧十条硬规矩

1. **只用 `...W` API**，内部 UTF-8、边界转 UTF-16。
2. **`GetLastError()` 紧跟失败调用**，中间不插任何 API。
3. **每个句柄都要 `CloseHandle`**，失败路径也算。
4. **`HANDLE` 判空要分清**：`INVALID_HANDLE_VALUE` 还是 `NULL`，看文档。
5. **线程用 `_beginthreadex`**（C 代码），C++ 用 `std::thread`。
6. **进程内互斥用 `CRITICAL_SECTION`**，不用 `Mutex`。
7. **`OVERLAPPED` 不能是栈上临时变量**，且完成前不可复用。
8. **跨 DLL 不传堆内存、不传 STL 容器、不让异常穿越**。
9. **路径处理考虑 `MAX_PATH`**，需要长路径就 `\\?\` 前缀。
10. **`HRESULT` 用 `SUCCEEDED`/`FAILED` 判**，不写 `== S_OK`。

---

## 十五、什么时候该用平台专属 API

不是所有东西都要"可移植"。判断标准：**这个能力有没有跨平台等价物**。

| 场景 | 建议 |
| --- | --- |
| 文件读写、线程、互斥、socket | 用可移植封装（`os_*.h`） |
| 高并发网络服务 | **各写各的**：Linux `epoll`、Windows IOCP。硬套会两头不讨好 |
| 目录监视 | 抽象成 `watch_dir(cb)`，底层 inotify / ReadDirectoryChangesW |
| 服务/守护进程 | 抽象成 `run_as_service()`，底层 systemd / SCM |
| 崩溃转储 | 抽象成 `install_crash_handler()`，底层 core dump / MiniDump |
| 注册表、COM、服务控制 | **只写 Windows 版**，Linux 侧给空实现或报 `ENOSYS` |

**不要为了"统一"把 IOCP 包成 epoll**——那是两大平台最经典的架构错误。
正确的抽象层是"**业务语义**"（如 `start_accepting(port, on_connection)`），不是"**系统调用语义**"。
