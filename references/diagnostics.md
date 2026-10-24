# 诊断：崩溃、泄漏、卡死、乱码

> 排查纪律：**先缩小范围，再改代码**。不要"看一眼觉得是这里"就动手；每一轮都要有可观察的证据（日志 / 断点 / 计数 / 转储）。

## 0. 症状 → 第一步做什么

| 症状 | 第一步 | 常见根因 |
| --- | --- | --- |
| 段错误 / 0xC0000005（随机位置） | 开 ASan 或拿 core dump 看栈 | 释放后使用、越界写坏堆、未初始化指针 |
| 崩溃总在同一函数 | 查该函数的缓冲长度与所有权 | off-by-one、`realloc` 用法、字符串未终止 |
| 只在 Release 崩 | 关闭 `-O2` 复现，再看 UB 清单 | UB 被优化暴露、`assert` 里放了副作用、未初始化变量读 |
| 只在 Windows 崩 / 只在 Linux 崩 | 对照 portability 的表逐项核 | `long` 宽度、CRLF、路径编码、删除已打开文件 |
| 内存持续增长 | 计数分配器 + 长跑 | 泄漏、缓存无上限、循环里重复开句柄 |
| CPU 100% / 卡死 | 抓两次栈（Linux `gdb -p`，Win 用 `!clrstack`-类或 Process Explorer 栈） | 死锁、忙等、无限重试循环、阻塞读无超时 |
| 文件打不开 / 权限莫名 | 打印真实路径与 `errno`/`GetLastError` | 中文路径走了 ANSI、`MAX_PATH` 超限、被占用 |
| 输出乱码 | 确认字节内容而非"看起来" | 控制台代码页、文本模式 CRLF、把 GBK 当 UTF-8 |
| 数据损坏但无崩溃 | 加 magic 与长度校验；用 ASan | 部分读写没循环、结构体直传、字节序 |

## 1. Linux 侧

### 1.1 core dump（最快拿到现场）

```bash
ulimit -c unlimited
cat /proc/sys/kernel/core_pattern        # 若是 |/usr/share/apport/... 则走 apport
gdb ./prog core
(gdb) bt full          # 完整栈 + 局部变量
(gdb) info locals
(gdb) frame 3
(gdb) p *ptr
(gdb) x/16xb buf        # 看原始字节
(gdb) thread apply all bt
```

### 1.2 gdb 常用速查

| 目的 | 命令 |
| --- | --- |
| 带参启动 | `gdb --args ./prog a b` |
| 断在失败处 | `break func if n > 100` |
| 观察内存被谁改 | `watch -l *(int*)0x...`（慢，慎用） |
| 追系统调用 | `catch syscall write` / 直接 `strace -f -e trace=file ./prog` |
| 栈溢出排查 | `bt` 看递归深度；`ulimit -s` |
| 打印结构体 | `p *ptr`，配合 `set print pretty on` |

### 1.3 strace / ltrace / proc

```bash
strace -f -tt -e trace=openat,read,write,close ./prog 2>&1 | tail -50
ltrace -f ./prog                 # 库调用（需支持）
ls -l /proc/<pid>/fd             # 句柄泄漏：fd 数量一直涨
cat /proc/<pid>/status | grep -E 'VmRSS|Threads'
cat /proc/<pid>/maps             # 段布局；找重复映射/大匿名段
```

### 1.4 valgrind（本机未安装）

```bash
valgrind --leak-check=full --show-leak-kinds=all --track-origins=yes ./prog
valgrind --tool=helgrind ./prog      # 数据竞争
```

## 2. Windows 侧

本机实测可用：**MSVC ASan**（`cl /fsanitize=address`）、**`/analyze`**、Debug CRT 堆检查。以下工具未安装，需要时再装：WinDbg/cdb、ProcDump、Application Verifier、DrMemory、Process Monitor（Sysinternals）。

### 2.1 立刻能用的三件套

```bat
:: 1) ASan（实测可跑；运行前需把 ASan 运行时目录加入 PATH）
cl /nologo /std:c17 /W4 /Zi /fsanitize=address prog.c /Fe:prog_asan.exe
set PATH=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64;%PATH%
prog_asan.exe
```

```c
/* 2) Debug CRT 堆检查（只对 /MDd /MTd 的 Debug 构建有效） */
#include <crtdbg.h>
int main(void)
{
    _CrtSetDbgFlag(_CRTDBG_ALLOC_MEM_DF | _CRTDBG_LEAK_CHECK_DF);
    _CrtSetReportMode(_CRT_WARN, _CRTDBG_MODE_FILE);
    _CrtSetReportFile(_CRT_WARN, _CRTDBG_FILE_STDERR);
    _CrtCheckMemory();                    /* 关键路径前后各插一次，定位堆被踩的位置 */
    return 0;
}
```

```powershell
# 3) WER 本地转储：崩溃时自动落 .dmp（注册表，需一次设置）
$k = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps'
New-Item -Path $k -Force | Out-Null
New-ItemProperty -Path $k -Name DumpFolder -Value 'C:\dumps' -PropertyType ExpandString -Force | Out-Null
New-ItemProperty -Path $k -Name DumpType   -Value 2 -PropertyType DWord -Force | Out-Null   # 2 = full
New-ItemProperty -Path $k -Name DumpCount  -Value 10 -PropertyType DWord -Force | Out-Null
```

拿到 `.dmp` 后用 WinDbg/cdb `!analyze -v`、`~*k`、`.ecxr` 分析。

### 2.2 句柄/资源泄漏

- 任务管理器 → 进程 → 添加"句柄""线程""提交大小"列，长跑观察单调增长。
- Sysinternals `handle.exe -p <pid>` 列出该进程持有的文件/事件/互斥量。
- 代码侧：所有 `Create*`/`Open*` 调用的返回值都要进 `cleanup`（见 style.md 的资源表）。

### 2.3 未安装但值得装的（按性价比）

| 工具 | 作用 |
| --- | --- |
| Sysinternals Process Monitor | 文件/注册表/网络访问的实时追踪，查"为什么打不开/读了哪个文件" |
| Application Verifier | 堆破坏、句柄误用、锁误用的运行时检查 |
| DrMemory | Windows 上的 valgrind 类工具（未初始化读、越界） |
| WinDbg (Store 版) | 转储分析、`!heap`、`!analyze -v` |
| ProcDump | 按条件（CPU/异常/内存阈值）抓转储 |

## 3. 没有 valgrind / ASan 时的自建观测（23 行）

这是本机最实用的手段：把分配计数与"泄漏嫌疑"直接打印出来。

```c
/* alloc_probe.c —— 用 -DPROBE_MALLOC 覆盖 malloc/free，仅用于本地排查 */
#include <stdio.h>
#include <stdlib.h>

static long g_live_blocks;
static long g_live_bytes;

static void *probe_alloc(size_t n, const char *file, int line)
{
    size_t *p = malloc(n + sizeof(size_t));
    if (p == NULL) return NULL;
    p[0] = n;
    g_live_blocks += 1;
    g_live_bytes += (long)n;
    (void)file; (void)line;
    return (void *)(p + 1);
}

static void probe_free(void *ptr)
{
    if (ptr == NULL) return;
    size_t *p = (size_t *)ptr - 1;
    g_live_blocks -= 1;
    g_live_bytes -= (long)p[0];
    free(p);
}

void probe_report(const char *tag)
{
    fprintf(stderr, "[alloc] %s: live=%ld blocks, %ld bytes\n",
            tag, g_live_blocks, g_live_bytes);
}
```

用法：把 `malloc/free` 用宏映射到 `probe_alloc/probe_free`，在关键阶段调用 `probe_report("after open")`。live 计数不回到 0 的位置就是泄漏区间——比全量 valgrind 更快定位"哪一段没释放"。

配合**失败注入**（在 probe_alloc 里按第 N 次调用返回 NULL）可以覆盖 OOM 分支：OOM 路径是最容易漏测、也最容易崩的分支。

## 4. 乱码 / 编码问题排查（Windows 高频）

按顺序确认，不要猜：

1. **字节层面**：把字符串按字节打印出来（`%02x`），确认它到底是不是 UTF-8。
   - `E4 B8 AD` = "中" 的 UTF-8；`D6 D0` = 同字的 GBK。字节就能定案。
2. **源文件编码**：MSVC 必须 `/utf-8`；否则窄字符串字面量按本地代码页解释。
3. **控制台**：`chcp` 看当前代码页；UTF-8 输出需 `SetConsoleOutputCP(CP_UTF8)`（老控制台还要换字体）。
4. **文件路径**：`fopen` 走 ANSI → 中文路径失败。改用 `_wfopen` + `utf8_to_wide`。
5. **命令行参数**：`main` 的 `argv` 是 ANSI；要 UTF-16 用 `wmain` 或 `GetCommandLineW`。
6. **文件内容**：用 `"rb"/"wb"`，排除 CRLF 干扰后仍乱码 → 就是编码问题，走上面 1–3。

## 5. 死锁与卡死

- 统一加锁顺序（在头文件里写清锁层级：`L1 → L2 → L3` 只能升序）。
- 用带超时的锁（`pthread_mutex_timedlock`、`WaitForSingleObject(h, ms)`）做排查版构建，超时即打印持有者。
- 抓两份间隔 5 秒的栈：都在等锁 → 死锁；都在同一循环 → 忙等/活锁。
- Windows 侧用 Process Explorer 的线程栈 + `~*k`；Linux 用 `gdb -p <pid> -ex "thread apply all bt"`。
- **阻塞 I/O 无超时**是最常见的"卡死"来源：socket 读、管道读、`waitpid`、`fread` 于 FIFO。

## 6. 诊断输出的规范（让日志真的能用）

- 每行带：时间（单调+墙钟）、级别、模块、线程 id、函数名；错误行带错误码与关键参数。
- 失败路径**一定要**有输出（没有日志的失败分支等于隐形 bug）。
- 二进制问题打十六进制 + 长度；不要只打 `"%s"`。
- 崩溃前 `fflush(stderr)`；信号处理器里只用 async-signal-safe 函数（`write` 可以，`printf`/`malloc` 不行）。
- 复现命令写进 issue：完整命令行、输入文件、环境（`uname -a` / `ver`、编译器版本、构建档位）。
