---
name: c-systems-standards
description: C 与 C++ 工程规范 + Linux/POSIX ↔ Windows/Win32 系统编程手册。用于写/改/审/移植 C/C++ 代码：命名与头文件规范、错误处理与内存所有权、整数与未定义行为、RAII 与移动语义、异常与错误码取舍、CMake 与 gcc/g++/clang/MSVC 严格警告门禁、sanitizer 与调试、两个平台的**专属机制**（Linux 的 fork/epoll/signalfd/capabilities/ELF，Windows 的 HANDLE·UTF-16/IO 完成端口/Job·SEH/注册表·服务·COM）与差异对照（文件/线程/进程/socket/时间/编码/换行/ABI）。含可直接运行的自检脚本与 30 项自审清单。
whenToUse: 用户要求写/改/审查 C 或 C++ 代码；排查段错误、内存泄漏、双重释放、signed/unsigned 陷阱、未定义行为、迭代器失效、对象切片；要求跨平台（Linux↔Windows）或把 Linux 代码移植到 Windows；涉及平台专属能力（epoll/signalfd/fork/capabilities/ld.so · IOCP/HANDLE 继承/Job Object/SEH/注册表/Windows 服务/COM）；配置编译警告档、CMake、ASan/valgrind/gdb/WinDbg、core dump 或 minidump；设计 C API 与 C/C++ 混编边界、头文件、错误处理约定；用户抱怨"代码不规范/风格乱/警告一大堆/为什么在 Linux 能跑 Windows 崩"。
---

# C / C++ 工程规范与跨平台系统编程

这份 skill 有四个目标，按优先级：
1. **写出来就规范**：接口、错误处理、内存所有权有固定套路，不靠临场发挥。
2. **写完能证明**：严格警告档 + 静态分析门禁跑绿，才算"完成"。
3. **平台差异不靠猜**：Linux 与 Windows 的差异是查表得出的，不是"应该差不多"。
4. **用对平台专属能力**：两个系统各自最强的那套机制（epoll/IOCP、signalfd/SEH、fork/CreateProcess）不能机械互译——各读各的手册。

## 怎么用（先看路由，再只读需要的文件）

| 当前任务 | 读哪个 |
| --- | --- |
| 写 C 新模块 / 定 API / 改既有代码风格 | `references/style.md` |
| 写 C++（类设计、RAII、智能指针、异常、模板、混编、ABI） | `references/cpp.md` |
| 跟时间、线程、进程、socket、文件、编码、路径、ABI 有关（两边通用差异） | `references/portability.md` |
| 用 Linux 专属能力（fork/exec、signal、epoll、inotify、capabilities、namespace、ELF/ld.so、io_uring） | `references/platform-linux.md` |
| 用 Windows 专属能力（HANDLE、UTF-16、IOCP、Job Object、注册表、服务、COM、SEH、minidump） | `references/platform-windows.md` |
| 整数、字符串、缓冲、内存、errno、未定义行为 | `references/ub-and-data.md` |
| 建工程、写 CMake、配编译选项、导出符号、开 sanitizer | `references/build.md` |
| 崩溃定位、内存增长、卡死、乱码、文件打不开 | `references/diagnostics.md` |
| 提交前自查 / 审别人的 C 或 C++ 代码 | `references/review.md` |

绝对路径（本机）：`C:\Users\asus\.dsh\skills\c-systems-standards\` 下的 `references\`、`scripts\`、`assets\`。
读参考文件用 read 工具读绝对路径；不要凭记忆复述参考里的内容——引用了什么就说什么。

---

## 一、十条硬规则（违反任一条就是缺陷，不是风格问题）

1. **缓冲必带长度**：任何接收缓冲区的函数，参数里必须有 `size_t cap`，并检查并拒绝 `cap == 0`；返回值必须能区分"截断"和"失败"。
2. **禁止无界字符串函数**：`strcpy` `strcat` `sprintf` `gets` `vsprintf` 一律不用。用 `snprintf`、`memcpy`（长度已校验）、`strlcpy` 仅当平台已有（Windows/MSVC 没有，自己写一个 `if_ok` 版本）。
3. **长度与指针成对**（slab 约定）：`f(const void *src, size_t src_len)`、`f(void *dst, size_t dst_cap)`；参数顺序 `(dst, dst_cap, src, src_len)`。
4. **整数不用 `int` 装尺寸**：尺寸/偏移/计数用 `size_t`、`ptrdiff_t`、`int64_t`/`uint32_t`（有语义宽度时用定宽类型）。`int` 只用于"确实 32 位且不会溢出"的场合。禁止 `int` 与 `size_t` 混算。
5. **所有权写清楚**：每个指针要么是"调用方拥有"，要么是"被调用方接管"，要么是"借用，不释放"。在头文件注释里逐参数标注（`/* borrowed */` / `/* takes ownership */`）。函数不得返回指向内部可变状态的指针。
6. **返回值必查**：`malloc`/`realloc`/`fopen`/`read`/`write`/`close`（对 NFS/磁盘满有意义）/`pthread_*` 的返回值一个都不能丢。用 `(void)` 显式忽略时必须能说清为什么安全（如 `(void)printf(...)`）。
7. **单一出口清理**：多资源函数用 `goto cleanup;` 逆序释放，每层只释放一类资源；不要在每个 `return` 前手抄释放代码。
8. **平台差异集中在一层薄封装**：业务代码里不出现 `#ifdef _WIN32`。所有平台差异收敛到 `os_*.c`（或一段集中注释的适配层），上层只调统一名字。
9. **文本/二进制、编码、换行显式写**：Windows 上 `fopen(path, "r")` 会做 CRLF 转换，二进制数据必须 `"rb"`；CSV/协议/字节流永远 `"rb"/"wb"`。跨平台文件用 UTF-8，Windows 上不要假设 `char*` 是 UTF-8（见 portability）。
10. **零警告是门禁**：交付前必须跑通严格警告档（见第三节），并消除全部警告——不是"这个警告不要紧"。

---

## 一·B、写 C++ 时的五条硬规则（细节见 `references/cpp.md`）

1. **不写裸 `new`/`delete`**：资源用 RAII 对象持有（`std::unique_ptr`/`std::string`/`std::vector`/自有句柄类）。需要多态删除时基类析构函数必须 `virtual`（否则 `-Wnon-virtual-dtor` 会抓）。
2. **Rule of Zero 优先**：能不给类写析构/拷贝/移动，就别写；必须自己管资源时，五个特殊成员函数要么全写要么全 `= delete`。
3. **所有权用类型表达**：`T*` 表示"可空、不拥有"；`T&` 表示"必定存在、不拥有"；拥有用 `std::unique_ptr<T>`，共享才用 `shared_ptr`（并说明为什么共享）。函数签名不允许出现"含义模糊的裸指针"。
4. **不用 C 风格转换**：`(T)x` 一律换成 `static_cast`/`const_cast`（后者必须注释理由）；`-Wold-style-cast` 门禁挡住它。
5. **错误处理全项目统一**：异常 与 `std::optional`/返回码 二选一，写在头文件里一致执行；混用时必须在边界处显式转换（`noexcept` 边界上不允许异常逃逸）。析构函数与 `noexcept` 函数内不得抛。

**C/C++ 混编边界**：对外 C ABI 头文件用 `extern "C"`，内部不泄漏 STL 类型到边界；跨 DLL 分配/释放必须同源（Windows 两套 CRT 堆）；`inline` 变量/函数在头文件里必须 `inline`，否则 ODR 冲突。

---

## 二、写代码的固定流程（照做，不要跳步）

```
1. 定契约       → 先写头文件：函数签名、所有权、错误码、不变量；此时不写实现
2. 写实现       → 自底向上（静态辅助函数先行），单一出口清理（C）/ RAII（C++）
3. 编译门禁     → scripts/check-c.ps1 或 check-c.sh，0 warning 才继续
4. 静态分析     → gcc/g++ -fanalyzer（本机实测能抓栈溢出）
5. 边界自测     → 空指针/0 长度/最大长度/截断/部分读/失败路径，各写一条断言
6. 自审清单     → references/review.md 的致命项逐条过
7. 汇报         → 说明：跑了什么门禁、覆盖了哪些边界、遗留什么未验证
```

**改既有代码时**：先读完相关文件与它们的调用点，再做最小改动；不顺手重排无关代码、不改无关格式、不删看不懂的注释。改动涉及 ABI/结构体布局时，必须同时更新 `_Static_assert`（C++ 用 `static_assert`）。

---

## 三、本机可用的门禁命令（已实测，直接复制）

### gcc / g++ 严格档（MSYS2 mingw64，gcc/g++ 16.1.0）

C（`-std=c17`）：

```bash
gcc -std=c17 -O2 -g \
  -Wall -Wextra -Wpedantic -Werror \
  -Wshadow -Wconversion -Wsign-conversion \
  -Wcast-qual -Wcast-align -Wwrite-strings \
  -Wstrict-prototypes -Wmissing-prototypes -Wmissing-declarations -Wold-style-definition \
  -Wundef -Wvla -Wdouble-promotion -Wformat=2 -Wnull-dereference \
  -Wswitch-default -Wredundant-decls -Wimplicit-fallthrough \
  -c src.c -o src.o
```

C++（`-std=c++20`，把 C 专属的那几项换掉）：

```bash
g++ -std=c++20 -O2 -g \
  -Wall -Wextra -Wpedantic -Werror \
  -Wshadow -Wconversion -Wsign-conversion -Wfloat-conversion \
  -Wcast-qual -Wcast-align=strict -Wwrite-strings \
  -Wnon-virtual-dtor -Woverloaded-virtual -Wextra-semi -Wold-style-cast -Wuseless-cast \
  -Wundef -Wvla -Wdouble-promotion -Wformat=2 -Wnull-dereference \
  -Wswitch-default -Wredundant-decls -Wimplicit-fallthrough \
  -c src.cpp -o src.o
```

> `-Wbad-function-cast`/`-Wstrict-prototypes`/`-Wmissing-prototypes`/`-Wold-style-definition` 是 **C 专属**，传给 g++ 会直接报错；`-Wnon-virtual-dtor` 等是 **C++ 专属**。脚本已按扩展名自动分派，手写命令时别混。

脚本会递归展开目录、按扩展名选编译器与警告集、逐文件报错：

```powershell
& "C:\Users\asus\.dsh\skills\c-systems-standards\scripts\check-c.ps1" -Path .\src -Toolchain gcc
& "C:\Users\asus\.dsh\skills\c-systems-standards\scripts\check-c.ps1" -Path .\src -Toolchain gcc -Analyzer   # 加 -fanalyzer
& "C:\Users\asus\.dsh\skills\c-systems-standards\scripts\check-c.ps1" -Path .\src -Toolchain msvc          # 走 vcvars64
& "C:\Users\asus\.dsh\skills\c-systems-standards\scripts\check-c.ps1" -Path .\src -Std c++23              # 覆盖标准
```

POSIX / MSYS / WSL 侧：`check-c.sh <dir|files...>`，选项 `--analyzer` `--no-werror` `--cc=` `--cxx=` `--std=` `-I<dir>`。

**本机 bash 调用坑（已踩）**：PATH 里 `WindowsApps\bash.exe`（WSL 桩）会抢在 msys bash 前面，`bash script.sh` 或 `./script.sh`（shebang `#!/usr/bin/env bash`）会走到 WSL 并报 `execvpe(/bin/bash) failed`。正确姿势是把脚本当参数交给 msys bash：

```powershell
& 'C:\msys64\usr\bin\bash.exe' 'C:/Users/asus/.dsh/skills/c-systems-standards/scripts/check-c.sh' 'F:/proj/src'
```

### 本机工具链事实（实测，别写错）

| 项 | 状态 |
| --- | --- |
| gcc / g++ | `C:\msys64\mingw64\bin\gcc.exe`、`g++.exe` 均 16.1.0，可用；`-fstack-protector-strong`、`-D_FORTIFY_SOURCE=2`、`-fanalyzer` 均可用 |
| MSVC | VS2022 BuildTools，toolset 14.44，需 `VC\Auxiliary\Build\vcvars64.bat` 后使用 `cl`；`/std:c17`、`/std:c++20 /EHsc`、`/W4 /permissive- /utf-8` 可用 |
| cmake | 4.4.3；**没有 make / ninja / clang / clang-tidy / clang-format / gdb / lldb / cppcheck / valgrind** |
| cmake 生成器 | 有 Visual Studio 系与 NMake；`MinGW Makefiles` 需 mingw32-make（未装），`Unix Makefiles` 需 make（未装），Ninja 未装 → **本机优先 VS 生成器，或先装 mingw32-make** |
| gcc/g++ sanitizer | **ASan/UBSan 不可用**（无 `libasan`/`libubsan`），`-fsanitize=address` 直接链接失败 |
| MSVC sanitizer | **`cl /fsanitize=address` 可用**（实测编译+运行成功）。运行前需把 `...\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64` 加入 PATH，否则报 0xC0000135（找不到 `clang_rt.asan_dynamic-x86_64.dll`） |

没有 ASan 的场景用：`-fanalyzer` 静态分析 + 自建计数分配器（`references/diagnostics.md` 有实现）+ MSVC ASan 复核。

---

## 四、平台差异的思考顺序（每次涉及系统调用都走一遍）

1. **这个能力在两边的"概念"是什么**（fd ↔ HANDLE，fork ↔ CreateProcess，signal ↔ SEH/控制台事件）——概念不同就不要硬套同名封装。
2. **语义差异**（不只看名字）：`rename` 在 Windows 上目标存在会失败；打不开的文件在 Windows 上删不掉；`close` 与 `closesocket` 不能混用。
3. **数据类型差异**：Windows 是 **LLP64**——`long` 是 32 位，`size_t` 是 64 位；`ssize_t`、`off_t` 在 MSVC 不存在；`wchar_t` 是 16 位 UTF-16。
4. **编码与换行**：Windows 控制台默认 GBK、路径为 UTF-16、文本模式翻译 CRLF；Linux 单一 UTF-8、`\n` 不翻译。
5. **失败报告方式**：`errno` ↔ `GetLastError()`，且都要"调用后立刻取"。
6. 详细对照表在 `references/portability.md`；要深入某一侧时看 `references/platform-linux.md`（fork/epoll/signalfd/capabilities/namespace/ELF）或 `references/platform-windows.md`（HANDLE/UTF-16/IOCP/Job/SEH/注册表/服务/COM）——**先查表再写代码**。

**平台专属能力的取舍原则**：不要为了"代码看起来一样"而放弃平台最好的机制（Linux 上 epoll+非阻塞+边沿触发，Windows 上 IOCP 完成端口）；要做的是**薄统一接口 + 各自最优实现**，而不是把 IOCP 硬塞进 select 模型。反过来，纯业务逻辑与数据结构必须两边共用同一份代码。判断标准：这段代码里出现"平台专有名词"了吗？出现了就下沉到平台层。

---

## 五、高频坑 Top 12（先扫一眼，能挡掉大半返工）

1. `int len = strlen(s)` → `-Wconversion` 直接报；用 `size_t`。
2. `unsigned n = len - 1` 当下溢时变成 `4294967295` → 先判 `len > 0`。
3. `realloc(p, n)` 失败返回 NULL，直接用会丢掉原指针 → 用临时变量。
4. `snprintf` 返回"想要写的长度"，大于 `cap` 表示截断——必须判，别当成功。
5. `fopen(..., "r")` 读二进制（zip/png/protobuf）→ Windows 上数据被 CRLF 改写。
6. `long` 当 64 位用（Linux 是 64 位，Windows 是 32 位）→ 用 `int64_t` 或 `intptr_t`。
7. `read`/`write` 返回值小于请求长度没循环 → 部分读写导致数据丢失（且 `EINTR` 要重试）。
8. 把 `char*` 当 UTF-8 交给 Windows API → 中文路径/名字变 `??`；宽窄字符转换要显式。
9. `assert` 里放有副作用的表达式，Release 下副作用消失。
10. 结构体跨平台二进制直传（含 padding、endianness、`long`）→ 必须显式序列化。
11. 在 DLL 里 malloc、在 exe 里 free（两套 CRT 堆）→ 崩溃；分配与释放必须同一模块/同一 CRT。
12. 忽略 `close`/`fclose`/`fflush` 返回值，最后一段缓冲静默丢失。
13. **C++**：基类有虚函数但析构不 `virtual` → 派生类析构不执行、泄漏或崩溃。
14. **C++**：往容器里 `push_back` 后继续用旧迭代器/引用（`vector` 扩容会全搬）→ 悬垂。
15. **C++**：按值传多态对象（`void f(Base b)`）→ 对象切片，派生部分丢失。
16. **C++**：析构函数里抛异常 → 通常直接 `std::terminate`；`noexcept` 函数同理。
17. **Linux**：ET 模式 epoll 没读到 `EAGAIN` 就返回 → 事件再不来；fd 没设 `O_NONBLOCK` 会阻塞整个循环。
18. **Windows**：`CreateProcess` 传 `lpCommandLine` 时参数引号/转义全归调用方，且它**可能改写**那个缓冲区；有空格路径不加引号直接被拆成两个参数。
19. **Windows**：`WaitForMultipleObjects` 最多 64 个句柄；超过要分组或改用 IOCP/线程池等待。
20. **两边共有**：把"就绪模型"（select/epoll）思路直接翻译成"完成模型"（IOCP）——语义不同，照抄必错（`references/platform-windows.md` 有对照）。

---

## 六、把规范变成常驻约束（可选）

默认这份 skill 由模型按需加载（目录里一条描述，几乎无成本）。若希望**每个会话都强制**：
- 只把本文第一、二节的"硬规则 + 固定流程"摘成 ~30 行贴进 agent preset 的 prompt 段（承载在 preset 里，不占 skill 加载成本），细节仍留在这里按需读。
- 需要"自动执行门禁"（例如每次写完 C 自动跑脚本并把警告喂回模型）时，那才需要写成动态 Cordis 插件或宿主组合里的 plugin 行——插件随进程消失，不适合承载规范文本。

---

## 七、参考文件索引

- `references/style.md` — 命名、头文件、API 设计、错误码、清理模式、日志与断言、模块边界
- `references/cpp.md` — C 与 C++ 的取舍边界、标准选择、RAII 与五个特殊成员、所有权类型、异常 vs 错误码、ODR/inline、C++ 专属坑、门禁命令、自审清单
- `references/portability.md` — Linux ↔ Windows 概念/语义/类型/编码对照表，适配层原语清单
- `references/platform-linux.md` — Linux 专属：fork/exec、signal、epoll ET、inotify、capabilities、namespace/seccomp、ELF 与 ld.so、线程与时钟
- `references/platform-windows.md` — Windows 专属：内核对象与 HANDLE、UTF-16、IOCP、Job Object、`_beginthreadex`、注册表、SCM 服务、COM、SEH、minidump
- `references/ub-and-data.md` — UB 清单、整数提升与安全运算、字符串与缓冲、所有权、errno
- `references/build.md` — 三套编译选项、CMake 模板、导出符号与 ABI、sanitizer 可用性、可重现构建
- `references/diagnostics.md` — gdb/PDB/core dump/strace/ProcMon、泄漏计数分配器、症状→排查顺序
- `references/review.md` — 30 项自审清单、审阅固定顺序、危险模式 grep 清单
- `scripts/check-c.ps1`、`scripts/check-c.sh` — 严格编译门禁（按扩展名自动分派 C / C++ 编译器与警告集）
- `assets/CMakeLists.txt`、`assets/module.h`、`assets/module.c`、`assets/.clang-format` — 起手模板
