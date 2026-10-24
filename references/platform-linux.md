# Linux 专属机制：系统编程需要知道的那些"Linux 才有"的东西

这份文件不讲 POSIX 通用部分（那在 `portability.md`），
专讲 **Linux 特有的机制与行为**——什么时候该用、用了会踩什么、跟 Windows 怎么对应。

所有条目按"你会不会真的用到"排序，不是按字母序。

---

## 一、心智模型：三个基础事实

1. **一切皆文件**。设备、管道、socket、进程信息都是文件描述符或文件。`/proc`、`/sys` 是内核导出的伪文件系统，读它们等于调用内核接口。
2. **进程是 fork 出来的**。没有"创建进程"的系统调用，只有 `fork` 复制当前进程 + `execve` 换掉映像。这决定了子进程继承哪些资源。
3. **内核接口是稳定的，库接口不一定**。`syscall()` 号在 x86-64 上稳定；glibc 封装可能变。需要确定性时直接看 `man 2` 而不是 `man 3`。

---

## 二、进程：fork/exec 的语义细节

### fork 之后，哪些东西共享

| 资源 | fork 后 |
| --- | --- |
| 内存 | **写时复制**（COW），父子各有一份地址空间 |
| 打开的文件描述符 | **共享同一份文件偏移量**（这点最容易出事） |
| 文件描述符表 | 复制一份表，但表项指向同一个 `struct file` |
| 互斥锁 | **复制当前状态**——如果 fork 时别的线程正持锁，子进程里那把锁永远解不开 |
| 信号处理 | 继承，但待处理信号清空 |
| 环境变量、cwd、umask | 继承 |

```c
pid_t pid = fork();
if (pid == 0) {
    /* 子进程：只允许调 async-signal-safe 函数，不要 malloc、不要 printf */
    execl("/bin/ls", "ls", "-l", (char *)NULL);
    _exit(127);                    /* exec 失败 */
}
```

**多线程程序里 fork 是雷区**。标准做法：fork 后子进程只调 `execve`，
或者用 `posix_spawn`（glibc 内部可能用 `clone(CLONE_VFORK)`，但接口是安全的）。

### 僵尸与孤儿

```c
/* 父进程必须 wait，否则子进程变僵尸（占 PID，直到父进程退出） */
int status;
while (waitpid(pid, &status, 0) == -1 && errno == EINTR) { /* 重试 */ }
if (WIFEXITED(status))   printf("exit=%d\n", WEXITSTATUS(status));
else if (WIFSIGNALED(status)) printf("killed by %d\n", WTERMSIG(status));
```

不想阻塞就两种选择：
- `signal(SIGCHLD, SIG_IGN)` —— 让内核自动回收（副作用：`wait` 拿不到退出码）
- 双 fork：父 → 子 → 孙，子立刻退出，孙被 init 收养（daemon 标准套路）

### 进程组、会话、守护进程

```c
setsid();              /* 新会话，脱离控制终端 */
chdir("/");            /* 别占着别人的挂载点 */
umask(0);              /* 显式设定，别继承 */
/* 关闭 0/1/2 并重定向到 /dev/null 或日志 */
```

**判断自己是不是 daemon**：`getppid() == 1`（被 init 收养）。

---

## 三、信号：Linux 的"异步事件"机制

### 必须知道的语义

| 事实 | 影响 |
| --- | --- |
| 信号处理器里只能调 **async-signal-safe** 函数 | `printf`、`malloc`、`syslog` 都不安全 → 死锁或崩溃 |
| 信号会打断阻塞的系统调用 | `read` 返回 `-1/EINTR`，**必须重试** |
| 标准信号会合并（不排队） | 连发 10 个 `SIGUSR1`，处理器可能只跑 1 次 |
| `SA_RESTART` 让部分调用自动重启 | 但 `poll`/`select`/`epoll_wait` 不重启，仍要处理 `EINTR` |
| 信号是进程级的，不是线程级的 | 多线程里哪个线程收到是随机的 |

### 安全写法：信号处理器只做标记

```c
static volatile sig_atomic_t g_stop = 0;

static void on_term(int sig) {
    (void)sig;
    g_stop = 1;                 /* 唯一允许的动作 */
}

/* 主循环 */
while (!g_stop) {
    ssize_t n = read(fd, buf, sizeof buf);
    if (n < 0) {
        if (errno == EINTR) continue;      /* 被打断就重试，不是错误 */
        perror("read");
        break;
    }
    ...
}
```

### 更好的方式：把信号变成文件描述符

```c
sigset_t mask;
sigemptyset(&mask);
sigaddset(&mask, SIGTERM);
sigaddset(&mask, SIGINT);
sigprocmask(SIG_BLOCK, &mask, NULL);         /* 先阻塞，避免竞态 */

int sfd = signalfd(-1, &mask, SFD_NONBLOCK | SFD_CLOEXEC);
/* 之后把 sfd 丢进 epoll，收到可读事件就是收到信号 → 完全同步化 */
```

配套的 `timerfd_create()`（定时器变 fd）、`eventfd()`（计数器变 fd）是同一套思路：
**把异步事件统一成可 poll 的 fd**，主循环就永远只有一个 `epoll_wait`。

### 与 Windows 的对应

| Linux | Windows | 注意 |
| --- | --- | --- |
| `SIGINT` / `SIGTERM` | `SetConsoleCtrlHandler` / 服务控制 | Windows 没有真正的信号 |
| `SIGSEGV` | SEH `EXCEPTION_ACCESS_VIOLATION` | 都只适合记日志后退出 |
| `SIGKILL` | `TerminateProcess` | 都不可捕获 |
| `SIGCHLD` | 无对应 | 用 `WaitForSingleObject` 等进程句柄 |

---

## 四、I/O 模型：从阻塞到 io_uring

### 五种模型的选择

| 模型 | 适用 | 关键调用 |
| --- | --- | --- |
| 阻塞 I/O | 简单工具、线程数少 | `read` / `write` |
| 非阻塞 + `poll`/`epoll` | 网络服务、大量 fd | `epoll_create1` / `epoll_ctl` / `epoll_wait` |
| 信号驱动 | 少见，坑多 | `O_ASYNC` + `F_SETSIG` |
| `io_uring` | 高吞吐、大量 syscall | `io_uring_setup` / 提交队列 |
| 线程池 + 阻塞 | 计算型任务、文件 I/O | `pthread` 或 `std::thread` |

**文件 I/O 用 epoll 是无效的**：普通文件永远"就绪"，`epoll` 对磁盘文件不产生事件。
要异步文件 I/O 得用 `io_uring` 或 `AIO`，或者干脆丢线程池。

### epoll 的三个坑

```c
int ep = epoll_create1(EPOLL_CLOEXEC);
struct epoll_event ev = {0};
ev.events = EPOLLIN | EPOLLET;      /* 边缘触发：必须一次读到 EAGAIN */
ev.data.fd = fd;
epoll_ctl(ep, EPOLL_CTL_ADD, fd, &ev);
```

1. **水平触发 vs 边缘触发**：ET 模式下不读到 `EAGAIN` 就再也收不到事件（除非重新 `EPOLL_CTL_MOD`）。新手标准翻车点。
2. **`EPOLLERR`/`EPOLLHUP` 总是被上报**，即使没在 `events` 里请求。
3. **fd 关闭后事件残留**：`close(fd)` 不会自动从 epoll 移除，用 `EPOLL_CTL_DEL` 显式删；或者依赖 `EPOLL_CTL_DEL` 在 `close` 前调用。

### 零拷贝家族

| 调用 | 用途 |
| --- | --- |
| `sendfile(out_fd, in_fd, ...)` | 文件 → socket，数据不过用户态 |
| `splice()` | 任意两个 fd 之间搬数据，经管道中转 |
| `copy_file_range()` | 文件 → 文件，内核内拷贝，支持 reflink |
| `mmap()` + `write()` | 大文件随机访问 |

### 与 Windows 的对应

| Linux | Windows |
| --- | --- |
| `epoll` | **IOCP**（完成端口，语义是"完成通知"不是"就绪通知"，模型不同） |
| `io_uring` | `OVERLAPPED` + 完成端口 |
| `sendfile` | `TransmitFile` |
| `mmap` | `MapViewOfFile` |
| `O_NONBLOCK` | 重叠 I/O（`FILE_FLAG_OVERLAPPED`） |

**epoll 与 IOCP 不能互相套壳**。就绪模型和完成模型的代码结构完全不同。

---

## 五、文件与路径的 Linux 特性

| 特性 | 用法 | 说明 |
| --- | --- | --- |
| `O_CLOEXEC` | `open(path, O_RDONLY \| O_CLOEXEC)` | **每个 fd 都加**，否则 exec 后泄漏给子进程 |
| `O_TMPFILE` | `open(dir, O_TMPFILE \| O_WRONLY, 0600)` | 匿名临时文件，不用起名，进程退出自动删 |
| `pread`/`pwrite` | 带偏移读写，不改文件位置 | 多线程读同一文件的安全方式 |
| `fdatasync` vs `fsync` | `fdatasync` 只刷数据不刷元数据 | 日志/数据库性能差别明显 |
| `rename` | 同分区内原子替换 | **原子发布文件的标准做法**：写临时文件 → `fsync` → `rename` |
| `inotify` | 监听目录变化 | 注意：事件会合并、不递归、队列溢出会 `IN_Q_OVERFLOW` |
| `statvfs` | 查剩余空间 | Windows 对应 `GetDiskFreeSpaceEx` |
| 硬链接/软链接 | `link()` / `symlink()` | Windows 上普通用户默认做不了 |

### 符号链接的坑

```c
/* 打开时不跟随符号链接：防止 symlink 攻击 */
int fd = open(path, O_RDONLY | O_NOFOLLOW);

/* 检查是否被替换过（TOCTOU 防护） */
struct stat st;
fstat(fd, &st);              /* 用 fd 而不是路径 */
```

`access()` 检查权限再 `open()` 是经典 TOCTOU 漏洞——检查和使用之间文件可能被换掉。
**只用 fd 做校验**。

### 路径长度的现实

Linux 上 `PATH_MAX` 是 4096，但实际没有硬限制（可以 `chdir` 逐段走）。
不要用固定 `char buf[PATH_MAX]` 接 `realpath` 之外的路径——递归目录可能超。

---

## 六、权限与隔离：Linux 独有的安全层次

| 机制 | 作用 | 何时用 |
| --- | --- | --- |
| **capabilities** | 把 root 权限切成 40 个细粒度能力 | 需要绑低端口但不想给全 root：`CAP_NET_BIND_SERVICE` |
| **namespaces** | 隔离 PID/网络/挂载/用户等视图 | 容器的基础 |
| **cgroups v2** | 限制 CPU/内存/IO | 资源配额 |
| **seccomp-bpf** | 过滤系统调用 | 缩小攻击面 |
| **LSM**（SELinux/AppArmor） | 强制访问控制 | 发行版策略 |
| **`PR_SET_NO_NEW_PRIVS`** | 禁止 setuid 提权 | 沙箱必备 |

```c
/* 最小权限：放弃所有能力，只留需要的 */
prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);
```

**Windows 的对应**：ACL/SID + 完整性级别 + Job Object + AppContainer。
概念能对上，API 完全不同——`portability.md` 有对照表。

---

## 七、动态链接与 ELF

### 库的三种形态

| 形态 | 文件 | 链接方式 |
| --- | --- | --- |
| 静态库 | `libfoo.a` | `-lfoo` + 归档，代码进可执行文件 |
| 共享库（带 soname） | `libfoo.so.1` → `libfoo.so.1.2.3` | `-lfoo`，运行时按 soname 找 |
| 插件（dlopen） | `libfoo.so` | `dlopen` / `dlsym` |

### 运行时找库的顺序

1. `DT_RPATH`（可执行文件里的，除非有 `RUNPATH`）
2. `LD_LIBRARY_PATH` 环境变量
3. `DT_RUNPATH`
4. `/etc/ld.so.cache`（由 `ldconfig` 生成）
5. `/lib`、`/usr/lib`

**推荐 `-Wl,-rpath,'$ORIGIN/../lib'`**：库跟着可执行文件走，不污染系统目录、不依赖环境变量。

```bash
# 检查一个二进制依赖什么
ldd ./app
readelf -d ./app | grep -E 'RPATH|RUNPATH|NEEDED'
objdump -T libfoo.so | grep ' T '      # 导出符号
```

### 符号可见性

默认所有符号都导出 → 命名冲突 + 启动变慢。显式收紧：

```c
__attribute__((visibility("default"))) int api_entry(void);
/* 编译时 -fvisibility=hidden，只给要导出的加 default */
```

---

## 八、线程与调度

| 需求 | API | 注意 |
| --- | --- | --- |
| 线程绑定 CPU | `pthread_setaffinity_np` | 实时/低延迟场景 |
| 线程命名 | `pthread_setname_np` | 只在 `/proc/PID/task/TID/comm` 里可见，`top`/`ps -L` 能看到 |
| 实时优先级 | `pthread_setschedparam` + `SCHED_FIFO` | 需要 `CAP_SYS_NICE`，写错会锁死系统 |
| 一次性初始化 | `pthread_once` | 比手写双重检查可靠 |
| 线程本地存储 | `_Thread_local`（C11）/ `thread_local` | 比 `__thread` 更标准 |

**`pthread_cancel` 不要用**：取消点是异步的，资源清理不可控。用标志位 + 条件变量让线程自己退出。

### 查看线程状态

```bash
cat /proc/<pid>/status          # Threads、VmRSS、voluntary_ctxt_switches
cat /proc/<pid>/task/*/stat     # 每个线程的状态
ls /proc/<pid>/fd               # 打开的文件描述符（排查泄漏）
cat /proc/<pid>/stack           # 内核态栈（需要权限）
cat /proc/<pid>/smaps_rollup    # 内存分布汇总
```

---

## 九、时间

| 时钟 | 用途 | 特点 |
| --- | --- | --- |
| `CLOCK_REALTIME` | 墙上时间、日志时间戳 | **会被 NTP 调整，会跳变** |
| `CLOCK_MONOTONIC` | 测量时间间隔、超时 | 不受系统时间调整影响 |
| `CLOCK_BOOTTIME` | 含挂起时间的单调时钟 | 移动设备 |
| `CLOCK_PROCESS_CPUTIME_ID` | 本进程 CPU 时间 | 性能测量 |

```c
/* 测量耗时永远用 MONOTONIC */
struct timespec t0, t1;
clock_gettime(CLOCK_MONOTONIC, &t0);
do_work();
clock_gettime(CLOCK_MONOTONIC, &t1);
long long us = (t1.tv_sec - t0.tv_sec) * 1000000LL
             + (t1.tv_nsec - t0.tv_nsec) / 1000;
```

**不要用 `gettimeofday` 测耗时**（会跳变），也不要在超时计算里用 `time(NULL)`（精度 1 秒）。

Windows 对应：`QueryPerformanceCounter`（单调高精度）、`GetSystemTimePreciseAsFileTime`（墙上）。

---

## 十、诊断：Linux 侧工具箱

| 症状 | 第一步 | 命令 |
| --- | --- | --- |
| 段错误 | 拿栈回溯 | `gdb ./app core` 或 `ulimit -c unlimited` + `/proc/sys/kernel/core_pattern` |
| 内存持续增长 | 看是谁在分配 | `valgrind --leak-check=full`（慢但准）、`heaptrack`、`/proc/pid/smaps_rollup` |
| 卡死 | 看每个线程的栈 | `gdb -p <pid>` → `thread apply all bt` |
| 系统调用失败 | 看真实返回值 | `strace -f -e trace=file ./app` |
| 打开的文件太多 | 数 fd | `ls /proc/<pid>/fd \| wc -l`、`lsof -p <pid>` |
| 性能热点 | 采样 | `perf top -p <pid>`、`perf record -g` |
| 文件被谁占着 | 查持有者 | `fuser -v path`、`lsof path` |

### core dump 没生成？按顺序查

```bash
ulimit -c                 # 0 表示禁用
cat /proc/sys/kernel/core_pattern    # 可能被 systemd-coredump 或 apport 接管
cat /proc/sys/fs/suid_dumpable       # setuid 程序默认不 dump
```

---

## 十一、Linux vs Windows 特有机制的速查对照

| 能力 | Linux 做法 | Windows 做法 |
| --- | --- | --- |
| 事件循环 | `epoll`（就绪） | IOCP（完成） |
| 定时器 | `timerfd` | `CreateWaitableTimer` |
| 目录监视 | `inotify` | `ReadDirectoryChangesW` |
| 内存映射 | `mmap` | `CreateFileMapping` + `MapViewOfFile` |
| 共享内存 | `shm_open` + `mmap` | `CreateFileMapping`（命名） |
| 命名管道 | `mkfifo` / Unix socket | `CreateNamedPipe` |
| 进程间同步 | 信号量、`flock`、POSIX shm | `Mutex`/`Semaphore`/`Event`（命名对象） |
| 线程本地存储 | `_Thread_local` | `TlsAlloc` / `__declspec(thread)` |
| 动态加载 | `dlopen`/`dlsym` | `LoadLibrary`/`GetProcAddress` |
| 服务/守护进程 | `systemd` unit / 双 fork | SCM（`CreateService`） |
| 权限模型 | uid/gid + capabilities | SID/ACL + 令牌 |
| 崩溃转储 | core dump | `MiniDumpWriteDump` / WER |
| 系统信息 | `/proc`、`sysinfo` | 注册表、`GetSystemInfo` |
| 高精度计时 | `clock_gettime` | `QueryPerformanceCounter` |

---

## 十二、写 Linux 代码的十条硬规矩

1. **每个 fd 都带 `O_CLOEXEC`**，socket 用 `SOCK_CLOEXEC`。
2. **每个可能返回 `EINTR` 的调用都要循环重试**。
3. **信号处理器里只置标志位**，其他一律不做。
4. **改文件用"临时文件 + `fsync` + `rename`"**，保证原子性。
5. **测耗时用 `CLOCK_MONOTONIC`**，不用 `gettimeofday`。
6. **多线程里不 fork**；要起进程用 `posix_spawn`。
7. **`fork` 后子进程只调 `execve` 或 async-signal-safe 函数**。
8. **校验权限用 `fstat(fd)`**，不用 `access(path)`。
9. **`epoll` 边缘触发必须读到 `EAGAIN`**。
10. **库导出符号显式收窄**（`-fvisibility=hidden` + `default` 标注）。
