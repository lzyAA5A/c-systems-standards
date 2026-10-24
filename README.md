# c-systems-standards

> C 与 C++ 工程规范 + Linux/POSIX ↔ Windows/Win32 系统编程手册。
> 一个给 AI 编码助手用的技能包（DeepSeek Harness Skill）。

模型写 C/C++ 代码，默认目标只是「能过编译器」。
这个技能把目标改成「能过 code review、能扛住生产环境、能在两个平台上都跑对、并且用对每个平台最强的那套机制」。

---

## 它解决什么问题

C 的失败模式是**静默的**。同一行代码在 Linux 上跑得好好的，到 Windows 上 `long` 从 64 位变 32 位；
`snprintf` 截断不报错，只是悄悄少写几个字节；少一次 `free` 要到三天后内存告警才暴露。
C++ 把问题换了个形状但没减少：基类析构少个 `virtual` 就泄漏，容器扩容后旧迭代器直接悬垂，
对象按值传递悄悄切片。这些问题编译器大多不吭声，测试也未必覆盖。

再往上还有一层：**两个平台的系统能力不是同构的**。Linux 有 fork、epoll、signalfd、capabilities；
Windows 有 HANDLE 继承、IOCP、Job Object、SEH、注册表与 SCM。把一边的思路硬翻译到另一边，
代码能编译、能跑、然后在压力下崩得莫名其妙。

这个技能把已知的高频坑整理成**可检查的规则**，把两个平台的差异整理成**查得到的表**，
并给 AI 一套固定的工作流：写之前先定契约，写之后必须过编译门禁、静态分析、边界自测和自审清单，才允许交付。

---

## 目录结构

```
c-systems-standards/
├── SKILL.md                    # 入口：路由表、硬规则、固定工作流、平台差异思考顺序
├── references/
│   ├── style.md                # 命名、头文件、API 设计、错误码、资源配对、模块边界
│   ├── cpp.md                  # C++ 取舍边界、RAII、所有权类型、异常 vs 错误码、ODR、ABI
│   ├── portability.md          # LP64 ↔ LLP64、类型、编码、线程、socket、CRT 差异
│   ├── platform-linux.md       # Linux 专属：fork/exec、signal、epoll、capabilities、ELF
│   ├── platform-windows.md     # Windows 专属：HANDLE、UTF-16、IOCP、Job、服务、COM、SEH
│   ├── ub-and-data.md          # 未定义行为、整型提升、溢出检查、字符串、所有权
│   ├── build.md                # gcc/g++/clang/MSVC 严格档、CMake 门禁、ABI、sanitizer
│   ├── diagnostics.md          # 崩溃、泄漏、卡死、乱码的定位手法
│   └── review.md               # 30 项自审清单 + 审 C/C++ 代码的 7 步
├── scripts/
│   ├── check-c.ps1             # Windows 侧门禁（gcc/g++ 或 MSVC，按扩展名分派）
│   └── check-c.sh              # POSIX 侧门禁（同上）
└── assets/
    ├── CMakeLists.txt          # 跨平台工程骨架，含警告门禁
    ├── module.h / module.c     # 不透明句柄 + 溢出检查 + 截断检测的参考实现
    └── .clang-format           # 风格声明
```

---

## 安装

技能放在这些目录之一即可被识别（按优先级）：

| 位置 | 作用域 |
| --- | --- |
| `~/.dsh/skills/` | 当前用户，所有项目 |
| `<项目>/.dsh/skills/` | 单个项目 |
| `<项目>/.agents/skills/` | 单个项目（agents 约定） |

```bash
git clone https://github.com/lzyAA5A/c-systems-standards.git
cp -r c-systems-standards ~/.dsh/skills/
```

Windows PowerShell：

```powershell
git clone https://github.com/lzyAA5A/c-systems-standards.git
Copy-Item -Recurse c-systems-standards "$env:USERPROFILE\.dsh\skills\c-systems-standards"
```

验证：技能列表里出现 `c-systems-standards`，描述包含「C 与 C++ 工程规范」。

---

## 硬规则（摘要）

完整版见 [`SKILL.md`](SKILL.md)。

### C

1. **先定契约再写实现**——谁分配、谁释放、失败返回什么、长度怎么传，写进头文件注释。
2. **每个可能失败的系统调用都要处理**——`read` 返回 0 / -1 / 短读是三种不同的事。
3. **单一出口 + `goto cleanup`**——多出口是泄漏的主要来源。
4. **长度参数紧挨指针**——`(dst, dst_cap, src, src_len)`，不靠猜。
5. **不用无界函数**——`strcpy` / `strcat` / `sprintf` / `gets` 一律禁用。
6. **整数不跨类型比较**——`size_t` 和 `int` 混用前先想清楚谁可能是负的。
7. **平台差异集中到 `os_*.h`**——业务代码里不出现 `#ifdef _WIN32`。
8. **编译门禁不可绕过**——`-Wall -Wextra -Werror` 或 `/W4 /WX`，警告即错误。
9. **交付前跑静态分析 + 边界自测**——`-fanalyzer`、`/analyze`、空指针、0 长度、超长输入。
10. **改完要汇报改了什么、验证了什么、还剩什么**——不写「已完成，请测试」。

### C++

11. **不写裸 `new`/`delete`**——资源交给 RAII；有虚函数的基类析构必须 `virtual`。
12. **Rule of Zero**——能不给类写析构/拷贝/移动就不写；必须管资源时，五个特殊成员函数要么全写要么全 `= delete`。
13. **所有权写进类型**——`T*` 可空不拥有、`T&` 必定存在不拥有、拥有用 `unique_ptr`，共享要说明理由。
14. **不用 C 风格转换**——`-Wold-style-cast` 挡住 `(T)x`。
15. **错误处理全项目统一**——异常与返回码二选一；析构与 `noexcept` 函数内不得抛。

### 两个平台

16. **平台专属能力各用各的最优机制**——薄统一接口 + 各自实现，不把 IOCP 硬塞进 `select` 模型。
17. **先查表再写代码**——`portability.md`（通用差异）→ `platform-linux.md` / `platform-windows.md`（专属机制）。

---

## 快速开始

### 写新模块

```
帮我用 C 写一个环形缓冲区，要求：
- 线程安全，单生产者单消费者
- 容量固定，初始化时指定
- 溢出时返回错误而不是丢弃
```

技能会让模型先给出头文件契约，再实现，最后跑门禁脚本自测。

### 写 C++

```
用 C++20 写一个事件循环的抽象层，底层 Linux 用 epoll、Windows 用 IOCP，
上层接口一致，不暴露平台类型
```

会先讲清楚两个模型的语义差异（就绪 vs 完成），再给出薄接口与两侧实现，而不是把 epoll 翻译成 IOCP。

### 审已有代码

```
审一下 src/parser.c，重点看内存和整数溢出
```

会按 30 项清单逐条过，输出分级结论（阻塞 / 建议 / 疑问）。

### 移植到 Windows

```
这段代码在 Linux 上没问题，帮我移到 Windows 并保持行为一致
```

会先列出平台差异点（类型宽度、路径、编码、线程、句柄语义），再改，不改业务逻辑。

---

## 配套脚本

门禁脚本不依赖技能上下文，可以单独用，也可以接进 CI。
脚本按**扩展名**分派：`.c` 走 gcc + C 专属警告；`.cpp/.cc/.cxx` 走 g++ + C++ 专属警告。

Windows：

```powershell
# gcc/g++ 通道（默认）
.\scripts\check-c.ps1 -Path src

# MSVC 通道，自动定位 vcvars64.bat，按扩展名选 /std:c17 或 /std:c++20
.\scripts\check-c.ps1 -Path src -Toolchain msvc

# 额外开静态分析
.\scripts\check-c.ps1 -Path src -Analyzer

# 覆盖语言标准 / 加头文件路径与自定义参数
.\scripts\check-c.ps1 -Path src -Std c++23 -Include include -Extra "-DDEBUG=1"
```

Linux / macOS / MSYS2：

```bash
./scripts/check-c.sh src
./scripts/check-c.sh --analyzer src
./scripts/check-c.sh --no-werror src        # 存量代码摸底：只报告不失败
./scripts/check-c.sh --cxx=clang++ --std=c++23 -I include src
```

脚本会递归收集 `.c/.cpp/.cc/.cxx`，跳过 `build/`、`.git/`、`out/`、`target/`、`.cache/`、`node_modules/`、`third_party/`、`cmake-build-*`，
只编译不链接，任一条警告即失败。

> **在 Windows 上跑 `.sh` 的坑**：PATH 里 `WindowsApps\bash.exe`（WSL 桩）会抢在 MSYS bash 之前，
> 导致 `bash script.sh` 或 `./script.sh` 走到 WSL 并报 `execvpe(/bin/bash) failed`。
> 正确写法是把脚本当参数交给 MSYS bash：
> `& 'C:\msys64\usr\bin\bash.exe' 'C:/path/to/check-c.sh' 'F:/proj/src'`。

---

## 参考手册索引

| 文件 | 什么时候翻 |
| --- | --- |
| [`references/style.md`](references/style.md) | 起新模块、定 API、纠结命名和参数顺序 |
| [`references/cpp.md`](references/cpp.md) | 用 C++ 而不是 C 的理由、类怎么写、异常还是错误码、C/C++ 混编 |
| [`references/ub-and-data.md`](references/ub-and-data.md) | 整数溢出、`snprintf` 截断、所有权、`errno`、序列化 |
| [`references/portability.md`](references/portability.md) | 同一份代码要跑 Linux 和 Windows |
| [`references/platform-linux.md`](references/platform-linux.md) | fork/exec、信号、epoll、inotify、capabilities、namespace、ELF |
| [`references/platform-windows.md`](references/platform-windows.md) | UTF-16、HANDLE、IOCP、Job Object、注册表、服务、COM、SEH |
| [`references/build.md`](references/build.md) | 配 CMake、开严格警告、接 sanitizer、发布二进制 |
| [`references/diagnostics.md`](references/diagnostics.md) | 段错误、内存泄漏、卡死、中文乱码 |
| [`references/review.md`](references/review.md) | 交付前自审、review 别人的 C/C++ 代码 |

---

## 工程骨架

`assets/` 里的三件套是可直接复制开工的最小工程：

- **`CMakeLists.txt`**——C17、警告门禁挂在 `INTERFACE` 目标上、导出宏、Windows 下自动加 `WIN32_LEAN_AND_MEAN` 与 `/utf-8`
- **`module.h` / `module.c`**——不透明句柄、`(dst, dst_cap, ...)` 参数顺序、溢出检查、截断检测、`_Static_assert` 校验线格式
- **`.clang-format`**——风格声明（本机没装 clang-format 时纯作规范用）

```bash
mkdir myproj && cp assets/* myproj/
```

---

## 已验证的工具链

内容里的每条平台结论都在下列环境实测过，不是抄文档：

| 工具 | 版本 / 状态 |
| --- | --- |
| gcc | 16.1.0（MSYS2 mingw64） |
| g++ | 16.1.0（C++20 门禁已实跑） |
| CMake | 4.4.3 |
| MSVC | 14.44.35207（VS 2022 Build Tools） |
| MSVC `/fsanitize=address` | 可用（需把 `Hostx64\x64` 加进 `PATH`） |
| gcc `-lasan` / `-lubsan` | **不可用**（该发行版未打包） |
| clang / clang-tidy / clang-format | 未安装 |
| gdb / lldb / valgrind / cppcheck | 未安装 |

技能里对「本机有什么、没有什么」是明写的，模型不会建议你跑一个装不上的命令。

---

## 怎么让它常驻生效

技能是**按需加载**的：模型判断任务匹配才会读它。想让它无条件生效，在项目根目录的 `AGENTS.md` 里写一行引用：

```markdown
写、改、审任何 C 或 C++ 代码前，先按 `~/.dsh/skills/c-systems-standards/SKILL.md` 的规则执行。
```

---

## 适用范围与局限

**适用**：系统编程、库开发、跨平台工具、需要长期维护的 C/C++ 代码、需要直接调平台机制（IO 模型、进程、权限、编码）的项目。

**不适用**：

- 一次性脚本（规范成本高于收益）
- 教学示例（会显得啰嗦）
- 已有强约定的代码库——那种情况应该服从既有风格，技能里也写了「先读现有代码再动手」

**已知局限**：门禁脚本只能发现编译器与静态分析能发现的问题。
逻辑错误、并发竞态、协议实现错误仍需人来判断；技能给的是排查路径，不是保证。

---

## 参考

- [C11 标准草案 N1570](https://www.open-std.org/jtc1/sc22/wg14/www/docs/n1570.pdf)
- [C++ 标准草案（eel.is/c++draft）](https://eel.is/c++draft/)
- [SEI CERT C Coding Standard](https://wiki.sei.cmu.edu/confluence/display/c/SEI+CERT+C+Coding+Standard)
- [SEI CERT C++ Coding Standard](https://wiki.sei.cmu.edu/confluence/pages/viewpage.action?pageId=88046682)
- [cppreference — Undefined behavior](https://en.cppreference.com/w/c/language/behavior)
- [Microsoft — 64-bit Windows 编程（LLP64）](https://learn.microsoft.com/en-us/windows/win32/winprog64/the-model)
