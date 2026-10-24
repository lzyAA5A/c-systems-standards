# c-systems-standards

> C 语言工程规范 + Linux/POSIX ↔ Windows/Win32 系统编程手册。
> 一个给 AI 编码助手用的技能包（DeepSeek Harness Skill）。

模型写 C 代码，默认目标只是「能过编译器」。
这个技能把目标改成「能过 code review、能扛住生产环境、能在两个平台上都跑对」。

---

## 它解决什么问题

C 的失败模式是**静默的**。同一行代码在 Linux 上跑得好好的，到 Windows 上 `long` 从 64 位变 32 位；
`snprintf` 截断不报错，只是悄悄少写几个字节；少一次 `free` 要到三天后内存告警才暴露。
这些问题编译器大多不吭声，测试也未必覆盖。

这个技能把已知的高频坑整理成**可检查的规则**，并给 AI 一套固定的工作流：
写之前先定契约，写之后必须过编译门禁、静态分析、边界自测和自审清单，才允许交付。

---

## 目录结构

```
c-systems-standards/
├── SKILL.md                  # 入口：路由表、十条硬规则、固定工作流、平台差异顺序
├── references/
│   ├── style.md              # 命名、头文件、API 设计、错误码、资源配对、模块边界
│   ├── portability.md        # LP64 ↔ LLP64、类型、编码、线程、socket、CRT 差异
│   ├── ub-and-data.md        # 未定义行为、整型提升、溢出检查、字符串、所有权
│   ├── build.md              # gcc/clang/MSVC 严格档、CMake 门禁、ABI、sanitizer
│   ├── diagnostics.md        # 崩溃、泄漏、卡死、乱码的定位手法
│   └── review.md             # 30 项自审清单 + 审 C 代码的 7 步
├── scripts/
│   ├── check-c.ps1           # Windows 侧门禁（gcc / MSVC 双通道）
│   └── check-c.sh            # POSIX 侧门禁
└── assets/
    ├── CMakeLists.txt        # 跨平台工程骨架，含警告门禁
    ├── module.h / module.c   # 不透明句柄 + 溢出检查 + 截断检测的参考实现
    └── .clang-format         # 风格声明
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

验证：技能列表里出现 `c-systems-standards`，描述包含「C 语言工程规范 + Linux ↔ Windows」。

---

## 十条硬规则（摘要）

完整版见 [`SKILL.md`](SKILL.md)。

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

### 审已有代码

```
审一下 src/parser.c，重点看内存和整数溢出
```

会按 30 项清单逐条过，输出分级结论（阻塞 / 建议 / 疑问）。

### 移植到 Windows

```
这段代码在 Linux 上没问题，帮我移到 Windows 并保持行为一致
```

会先列出平台差异点（类型宽度、路径、编码、线程），再改，不改业务逻辑。

---

## 配套脚本

门禁脚本不依赖技能上下文，可以单独用，也可以接进 CI。

Windows（gcc 或 MSVC 任选）：

```powershell
# gcc 通道（默认）
.\scripts\check-c.ps1 -Path src

# MSVC 通道，自动定位 vcvars64.bat
.\scripts\check-c.ps1 -Path src -Toolchain msvc

# 额外开静态分析
.\scripts\check-c.ps1 -Path src -Analyzer

# 加头文件路径与自定义参数
.\scripts\check-c.ps1 -Path src -Include include -Extra "-DDEBUG=1"
```

Linux / macOS / MSYS2：

```bash
./scripts/check-c.sh src
./scripts/check-c.sh --analyzer src
./scripts/check-c.sh --cc=clang -I include src
```

脚本会递归收集 `.c` 文件，跳过 `build/`、`.git/`、`out/`、`target/`、`.cache/`、`node_modules/`、`third_party/`、`cmake-build-*`，
只编译不链接，任一条警告即失败。

---

## 参考手册索引

| 文件 | 什么时候翻 |
| --- | --- |
| [`references/style.md`](references/style.md) | 起新模块、定 API、纠结命名和参数顺序 |
| [`references/ub-and-data.md`](references/ub-and-data.md) | 整数溢出、`snprintf` 截断、所有权、`errno`、序列化 |
| [`references/portability.md`](references/portability.md) | 同一份代码要跑 Linux 和 Windows |
| [`references/build.md`](references/build.md) | 配 CMake、开严格警告、接 sanitizer、发布二进制 |
| [`references/diagnostics.md`](references/diagnostics.md) | 段错误、内存泄漏、卡死、中文乱码 |
| [`references/review.md`](references/review.md) | 交付前自审、review 别人的 C 代码 |

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
| g++ | 16.1.0 |
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
写、改、审任何 C 代码前，先按 `~/.dsh/skills/c-systems-standards/SKILL.md` 的规则执行。
```

---

## 适用范围与局限

**适用**：系统编程、库开发、跨平台工具、需要长期维护的 C 代码。

**不适用**：

- 一次性脚本（规范成本高于收益）
- 教学示例（会显得啰嗦）
- 已有强约定的代码库——那种情况应该服从既有风格，技能里也写了「先读现有代码再动手」

**已知局限**：门禁脚本只能发现编译器能发现的问题。
逻辑错误、并发竞态、协议实现错误仍需人来判断；技能给的是排查路径，不是保证。

---

## 参考

- [C11 标准草案 N1570](https://www.open-std.org/jtc1/sc22/wg14/www/docs/n1570.pdf)
- [SEI CERT C Coding Standard](https://wiki.sei.cmu.edu/confluence/display/c/SEI+CERT+C+Coding+Standard)
- [cppreference — Undefined behavior](https://en.cppreference.com/w/c/language/behavior)
- [Microsoft — 64-bit Windows 编程（LLP64）](https://learn.microsoft.com/en-us/windows/win32/winprog64/the-model)
