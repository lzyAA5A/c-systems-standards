# 构建、编译选项与 ABI

> 目标：**警告是门禁，不是建议**。一个工程只要允许"这条警告不要紧"，规范就退化成了个人偏好。

## 1. 三套编译选项（本机实测可用）

### 1.1 GCC / Clang（POSIX、MSYS2 mingw64）

```bash
CFLAGS="-std=c17 -O2 -g3 \
  -Wall -Wextra -Wpedantic -Werror \
  -Wshadow -Wconversion -Wsign-conversion -Wfloat-conversion \
  -Wcast-qual -Wcast-align=strict -Wwrite-strings -Wpointer-arith -Wbad-function-cast \
  -Wstrict-prototypes -Wmissing-prototypes -Wmissing-declarations -Wold-style-definition \
  -Wundef -Wvla -Walloca -Walloc-zero -Wdouble-promotion \
  -Wformat=2 -Wnull-dereference -Wstrict-overflow=2 \
  -Wduplicated-cond -Wlogical-op -Wjump-misses-init \
  -Wswitch-default -Wredundant-decls -Wimplicit-fallthrough \
  -fstack-protector-strong -fno-omit-frame-pointer"
```

- `-Wconversion -Wsign-conversion` 是这份规范里性价比最高的一对：它能抓掉 `int`/`size_t` 混算的绝大多数事故。**不要**因为"警告太多"关掉它——一开始就按它的要求写，比事后清理便宜十倍。
- `-Wswitch-enum` 只在你**确实**要穷举枚举时用；默认用 `-Wswitch-default` 避免噪声。
- `-Wformat-truncation=2` 不要默认开：它对"截断是正常分支"的 API（写调用方缓冲）会误报，实测会对着 `snprintf(dst, cap, "v%u.%u", ...)` 报 `region of size 0`。默认档（`-Wformat` 带 level 1）已经够用，确需严查时单独加。
- `-Werror` 在本地门禁与 CI 上开；发布分支也建议保留（否则警告会代际累积）。
- `-fanalyzer`（GCC 静态分析，实测能直接报 `stack-based buffer overflow [CWE-121]`）：单独一档、慢（大文件可慢数倍），建议在提测前跑一遍而不是每次增量编译都跑。
- `-D_FORTIFY_SOURCE=2` 需要 `-O2`；在 mingw 上作用有限（无 glibc），Linux 上必开。

### 1.2 MSVC（VS2022 BuildTools，需先 vcvars64）

```bat
cl /nologo /std:c17 /W4 /permissive- /utf-8 /Zc:preprocessor ^
   /GS /guard:cf /DYNAMICBASE ^
   /wd4100 ^
   /c src.c /Fo:src.obj
```

- `/W4` 是 MSVC 的实际硬门槛；`/Wall` 会打开大量无关噪声（含 C4xxx 信息级），不推荐。
- `/utf-8` **必须**加：否则源码里的中文按本地代码页解析，字符串字面量和 `char` 常量都可能变形。
- `/permissive-` 收紧标准一致性（C 模式下影响较小，但配合 C++ 混合项目必要）。
- `/std:c17` 取代旧的 `/std:c11`；MSVC 对 C11 支持是"部分"，`<threads.h>`、`<stdatomic.h>` 早年缺失（新版本部分支持，用前先测）。
- `/analyze` 是 MSVC 的静态分析：**它只报警告，不改变退出码**，要配合 `/WX` 或自己解析输出当作门禁。实测会给出 `C6387` 这类"可能是 0"的合理提示，也可能有误报，需人工判读。
- `/fsanitize=address`（见 §5）。

### 1.3 警告档的"分层"实践

| 层 | 选项 | 理由 |
| --- | --- | --- |
| 自己的代码 | 全套严格档 + `-Werror` | 规范主体 |
| 生成代码（protobuf 等） | 单独 target，降到 `-Wall` | 改不了 |
| 第三方头文件 | `-isystem`（GCC）/ `SYSTEM`（CMake） | 屏蔽其头文件警告，不影响本工程门禁 |

## 2. CMake 骨架（可直接用 `assets/CMakeLists.txt`）

```cmake
cmake_minimum_required(VERSION 3.20)
project(proj LANGUAGES C)

set(CMAKE_C_STANDARD 17)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)          # 严格 -std=c17，不用 gnu17

add_library(proj_warnings INTERFACE)
if (MSVC)
    target_compile_options(proj_warnings INTERFACE /W4 /permissive- /utf-8)
else()
    target_compile_options(proj_warnings INTERFACE
        -Wall -Wextra -Wpedantic -Werror
        -Wconversion -Wsign-conversion -Wshadow -Wcast-qual
        -Wstrict-prototypes -Wmissing-prototypes -Wvla -Wformat=2)
endif()

add_library(core src/buf.c src/os.c)
target_include_directories(core PUBLIC include)
target_link_libraries(core PRIVATE proj_warnings)
```

要点：
- 用**目标级**选项（`target_compile_options`），不用全局 `add_compile_options`——否则第三方代码也被 `-Werror` 绑架。
- `CMAKE_C_EXTENSIONS OFF`：`-std=c17` 而不是 `-std=gnu17`，才能发现"用了 GNU 扩展但以为是标准"的地方。
- 平台宏用 `target_compile_definitions` 下发，不要在源码里手写 `#define _WIN32`。
- **本机没有 make/ninja**：`cmake -G "MinGW Makefiles"` 需先装 `mingw32-make`；否则用 VS 生成器（本机实测可用）：
  - `cmake -S . -B build -G "Visual Studio 17 2022"` → 识别 MSVC 19.44 + Windows SDK 10.0.26100
  - `cmake --build build --config RelWithDebInfo` → 成功产出 `demo_core.lib`
  GCC 单文件验证不必走 CMake，直接 `gcc`/脚本更快。

## 3. 共享库与符号导出

| 平台 | 导出 | 导入 | 可见性 |
| --- | --- | --- | --- |
| Windows | `__declspec(dllexport)` | `__declspec(dllimport)` | 默认全部不导出（无自动导出，`/EXPORT` 例外） |
| Linux/macOS | `__attribute__((visibility("default")))` | （无需声明） | 默认**全导出**，要 `-fvisibility=hidden` 收紧 |

统一写法（一个宏解决两侧）：

```c
#if defined(_WIN32)
#  if defined(PROJ_BUILD)
#    define PROJ_API __declspec(dllexport)
#  else
#    define PROJ_API __declspec(dllimport)
#  endif
#else
#  define PROJ_API __attribute__((visibility("default")))
#endif
```

规则：
- 库的 `.c` 里编译定义 `PROJ_BUILD`，使用者不定义。
- Linux 侧同时加 `-fvisibility=hidden`，否则内部符号全泄漏、还可能符号冲突。
- 导出结构体必须注释 ABI 稳定性；改字段 = 改 ABI = 升主版本号。
- C 头文件一律 `extern "C"` 包裹（给未来的 C++ 使用者留门）。

## 4. ABI 稳定性检查

```c
/* 导出结构体：布局变了必须炸在编译期，而不是运行时 */
typedef struct proj_cfg {
    uint32_t version;
    uint32_t flags;
    uint64_t limit;
} proj_cfg_t;

_Static_assert(sizeof(proj_cfg_t) == 16, "proj_cfg_t ABI broken");
_Static_assert(offsetof(proj_cfg_t, limit) == 8, "proj_cfg_t ABI broken");
```

- 结构体首字段放 `version`/`struct_size`，允许调用方先探测大小（Windows 风格的 `cbSize`）。
- 不要在导出结构体里放 `bool`（跨编译器大小/对齐不保证）、`long`、位域、匿名 union。
- 函数指针参数跨 DLL 传递时确认调用约定（x64 只有一种约定，x86 有 `__cdecl`/`__stdcall`）。

## 5. Sanitizer 与静态分析（本机实测结论）

| 工具 | 本机状态 | 用法 |
| --- | --- | --- |
| GCC `-fanalyzer` | ✅ 可用 | `gcc -fanalyzer -c f.c`；实测抓到 `stack-based buffer overflow [CWE-121]` |
| GCC ASan/UBSan | ❌ **不可用**（无 `libasan`/`libubsan`） | `-fsanitize=address` 链接失败：`cannot find -lasan` |
| MSVC `/fsanitize=address` | ✅ 可用（实测编译+运行） | 运行前把 `VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64` 加入 PATH，否则 `0xC0000135` |
| MSVC `/analyze` | ✅ 可用（只报警告） | 配合 `/WX` 或解析输出做门禁 |
| valgrind / clang-tidy / cppcheck | ❌ 未安装 | 需要时在 WSL/Linux 侧做 |

ASan 的典型价值：USE_AFTER_FREE、heap-buffer-overflow、double-free、内存泄漏（`ASAN_OPTIONS=detect_leaks=1`，注意 Windows ASan 的泄漏检测支持有限）。没有 ASan 时的替代：`-fanalyzer` + 计数分配器（diagnostics.md）+ MSVC ASan 复核。

## 6. 构建变体与调试信息

| 变体 | 选项 | 用途 |
| --- | --- | --- |
| Debug | `-O0 -g3`（MSVC `/Od /Zi`） | 单步调试；注意 `-O0` 会掩盖 UB，**不要**只测 Debug |
| Release | `-O2 -g`（MSVC `/O2 /Zi`） | 交付；保留符号便于事后定位，`strip` 后再发布 |
| RelWithDebInfo | `-O2 -g -DNDEBUG` | 等价于线上，带调试信息——**这是应该跑测试的档位** |
| Hardened | `-O2 -D_FORTIFY_SOURCE=2 -fstack-protector-strong` | 安全敏感场景 |

- `-DNDEBUG` 会关掉 `assert`：所有"只在 assert 里做的检查"在 Release 消失，所以参数校验必须用返回值。
- 发布时 Windows 保留 `.pdb`（私有符号服务器），Linux 分离 `.debug`（`objcopy --only-keep-debug`）。
- 生产构建建议 `-fno-common`（GCC 10+ 默认）、`-Wl,-z,relro,-z,now`（Linux）。

## 7. 可重现构建（可选但会救你一次）

- 不要用 `__DATE__`、`__TIME__`、`__TIMESTAMP__`（每次编译都变）；需要版本信息就注入 `-DPROJ_VERSION="..."`。
- 路径泄漏：`-ffile-prefix-map=$(pwd)=.`。
- 归档顺序与时间戳：`ar rcsD`（`D` 为确定性模式）。
- 固定 `SOURCE_DATE_EPOCH` 给打包脚本。

## 8. 交叉编译与 Linux 侧验证

- 本机 `wsl` 存在但枚举被拒（未配置发行版）。要在 Linux 上验证时先确认 `wsl -l -v` 可用。
- 想在本机做"Linux 侧编译检查"，最小代价是 Docker/WSL 里跑同一份 `check-c.sh`。
- 交叉编译（mingw 交叉到 Windows / musl 静态）时注意：`sizeof(long)`、`wchar_t`、`locale` 都会随目标变；`-static` 会改变 dlopen 的可用性。

## 9. 交付前的构建门禁清单

- [ ] `-Werror` 下 0 警告（两个编译器都跑过，至少一个）
- [ ] `-fanalyzer`（或 `/analyze`）没有未解释的告警
- [ ] Debug 与 RelWithDebInfo 两种档都跑通
- [ ] 导出符号清单符合预期（`nm -D`/`dumpbin /exports`）
- [ ] `_Static_assert` 覆盖所有导出的结构体与协议头
- [ ] 构建脚本里没有硬编码绝对路径、没有 `__DATE__`
- [ ] 三方头文件通过 `-isystem`/`SYSTEM` 隔离
