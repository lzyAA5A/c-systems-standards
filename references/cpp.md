# C++：从 C 过渡到 C++ 的工程规范

C++ 不是"C 加类"。它有一套自己的失败模式：悬垂引用、对象切片、ODR 违规、ABI 不兼容、
隐式拷贝带来的性能悬崖。这份文件只讲**会出事的点**和**选型判断**，不教语法。

面向场景：把已有 C 代码升级到 C++、新写 C++ 模块、审 C++ 代码、C 与 C++ 混编。

---

## 一、什么时候该用 C++，什么时候不该

| 判断 | 用 C++ | 继续用 C |
| --- | --- | --- |
| 有 RAII 能消除的资源泄漏 | ✅ 析构函数是刚需 | — |
| 需要容器、字符串、算法 | ✅ 别手写动态数组 | — |
| 代码要跨 ABI 稳定交付（DLL/so 给第三方） | — | ✅ C ABI 最稳 |
| 极小的 freestanding 环境、内核态、无异常无 RTTI | — | ✅ |
| 团队只有 C 经验且项目已定型 | — | ✅ 混用成本高于收益 |
| 想用模板做零成本抽象 | ✅ | — |

**混编的铁律**：C++ 实现的库，对外的 `extern "C"` 接口必须是**纯 C 类型**。
不要在导出函数里出现 `std::string`、`std::vector`、异常、模板实例——那是 ABI 地雷（见第七节）。

---

## 二、标准选择

| 编译器 | 推荐档位 | 说明 |
| --- | --- | --- |
| gcc/g++ | `-std=c++20` | 本机 g++ 16.1.0 完整支持 C++20；C++23 大部分可用 |
| MSVC | `/std:c++20` | VS2022 17.x 完整支持；`/std:c++latest` 才给 C++23 子集 |
| 跨平台基线 | **C++17** | 三方库生态最稳；能上 20 就上 |

不用 `-std=gnu++20`（GNU 扩展会让你写出 MSVC 编不过的代码）。

**feature test 而不是版本判断**：

```cpp
#if defined(__cpp_concepts) && __cpp_concepts >= 201907L
    // 用 concepts
#else
    // 退化路径
#endif
```

---

## 三、五条硬规则

### 规则 1：不写裸 `new` / `delete`

```cpp
// ✗ 任何一处 new 都是一个未来的泄漏
auto *p = new Widget();

// ✓ 栈对象优先
Widget w;

// ✓ 必须堆分配时用智能指针
auto p = std::make_unique<Widget>();
```

例外只有两个：实现自己的容器/智能指针，以及在构造函数里接管外部指针且**立刻**交给成员智能指针。

### 规则 2：遵循 rule of zero，写不出五个就写零个

```cpp
// ✓ 全部让成员自己管，编译器生成的五个都对
class Session {
    std::string name_;
    std::vector<Frame> frames_;
    std::unique_ptr<Socket> sock_;
};
```

一旦你手写了析构函数，就必须同时考虑拷贝构造、拷贝赋值、移动构造、移动赋值——
否则编译器要么不生成（移动被抑制），要么生成出浅拷贝（双重 free）。

```cpp
class Handle {
public:
    explicit Handle(HANDLE h) noexcept : h_(h) {}
    ~Handle() { if (h_ != INVALID_HANDLE_VALUE) CloseHandle(h_); }

    // 资源不可复制
    Handle(const Handle &) = delete;
    Handle &operator=(const Handle &) = delete;

    // 可移动：move 后把源置空，否则析构会二次关闭
    Handle(Handle &&o) noexcept : h_(o.h_) { o.h_ = INVALID_HANDLE_VALUE; }
    Handle &operator=(Handle &&o) noexcept {
        if (this != &o) {
            reset();
            h_ = o.h_;
            o.h_ = INVALID_HANDLE_VALUE;
        }
        return *this;
    }

    HANDLE get() const noexcept { return h_; }

private:
    void reset() noexcept {
        if (h_ != INVALID_HANDLE_VALUE) CloseHandle(h_);
        h_ = INVALID_HANDLE_VALUE;
    }
    HANDLE h_;
};
```

### 规则 3：参数用引用，不用指针表达"可空"

| 语义 | 写法 |
| --- | --- |
| 只读，必须存在 | `const T &` |
| 可修改，必须存在 | `T &` |
| 可能为空 | `T *`（并在注释里写 `may be null`） |
| 只读字符串，不接管 | `std::string_view` |
| 只读字节块 | `std::span<const std::byte>` |
| 转移所有权 | `std::unique_ptr<T>` 按值 |
| 共享所有权 | `const std::shared_ptr<T> &` |

**`string_view` 是借用**：指向别人的字符数组。传进来的临时 `std::string` 析构后，
`string_view` 就悬垂。函数内不保存它、不返回它。

### 规则 4：禁止 C 风格强制转换

```cpp
// ✗ 四种语义混在一起，编译器不告诉你转错了
double d = (double) x;

// ✓ 一眼看出意图，且转错会编译失败
auto d = static_cast<double>(x);
auto *p = reinterpret_cast<std::byte *>(raw);
auto *q = const_cast<char *>(readonly);
auto *b = dynamic_cast<Base *>(obj);   // 失败返回 nullptr，可检查
```

### 规则 5：析构函数不抛异常

析构期间抛异常 → 栈展开过程中二次异常 → `std::terminate`。

```cpp
~Resource() noexcept {           // 默认就是 noexcept，显式写出来是提醒
    flushQuietly();              // 内部吞掉错误，只记日志
}
```

需要可靠落盘的东西**不要**放在析构里，提供显式 `close()` / `flush()` 让调用方处理错误。

---

## 四、错误处理的三选一（选完就要一致）

| 方式 | 什么时候用 | 代价 |
| --- | --- | --- |
| **异常** | 构造失败无法用返回值表达、错误罕见、调用链深 | 需要 `-fexceptions`，二进制体积，跨 DLL 有约束 |
| **错误码 / `std::optional`** | 高频调用、性能敏感、无异常环境（内核/嵌入式/部分游戏） | 每个调用点都要判，容易漏 |
| **`std::expected<T, E>`**（C++23） | 想两者兼得：显式错误 + 不丢信息 | 需要 C++23；本机 g++ 16 在 `-std=c++23` 下可用 |

选错误码时，让错误类型**不可忽略**：

```cpp
struct [[nodiscard]] Result {
    std::error_code ec;
    explicit operator bool() const noexcept { return !ec; }
};

[[nodiscard]] Result write_all(File &f, std::span<const std::byte> data);
```

`[[nodiscard]]` 让"忘了判返回值"变成编译警告，配合 `-Werror` 就是编译失败。

**不要混用**：库里抛异常、调用方按错误码处理，等于把异常变成未捕获的 terminate。

---

## 五、头文件、ODR 与编译期检查

### 头文件

```cpp
#pragma once                       // 比 include guard 短，所有主流编译器都认

#include <cstddef>                 // 先标准库
#include <string>

#include "project/detail/buf.hpp"  // 再项目内，路径从项目根写起
```

**头文件里不写 `using namespace std;`**——会污染所有包含者。
头文件里不定义非 `inline` 的函数或全局变量（多重定义 → 链接错误或 ODR 违规）。

### 该 inline 的东西

```cpp
// 头文件里定义函数 → 必须 inline，否则每个 TU 各有一份 → 链接错误
inline int clamp_positive(int v) noexcept { return v > 0 ? v : 0; }

// C++17：头文件里的变量用 inline
inline constexpr std::size_t kMaxRetry = 3;

// 模板和 constexpr 函数天然可以放头文件，不需要 inline 关键字
template <typename T> constexpr T square(T v) { return v * v; }
```

### 编译期断言代替注释

```cpp
static_assert(sizeof(WireHeader) == 16, "线格式必须 16 字节，改了要同步协议文档");
static_assert(std::is_trivially_copyable_v<WireHeader>, "必须可按字节拷贝");
static_assert(alignof(std::max_align_t) >= 16, "假定 16 字节对齐");
```

### 模板约束用 concepts（C++20）而不是 SFINAE 报错墙

```cpp
template <typename T>
    requires std::is_arithmetic_v<T>
T sum(std::span<const T> xs);
```

约束不满足时报错直接指向调用点，而不是 200 行模板展开。

---

## 六、容器与迭代器的坑

| 坑 | 后果 | 正确做法 |
| --- | --- | --- |
| 边遍历边 `erase` | 迭代器失效 → UB | `it = v.erase(it)`，或用 erase-remove |
| `push_back` 导致 realloc | 所有指针/引用/迭代器失效 | 先 `reserve(n)`，别在循环里持有元素指针 |
| `vector<bool>` | 不是容器，`&v[0]` 拿不到 `bool*` | 用 `std::vector<char>` 或 `std::bitset` |
| `v[i]` 越界 | 无检查 → UB | 用 `v.at(i)`（有检查，抛 `out_of_range`），热路径才用 `[]` |
| `std::map` 每次 `operator[]` 插入 | 查不到就创建默认值 | 查用 `find` / `contains` |
| `shared_ptr` 循环引用 | 永不释放 | 一端改 `weak_ptr` |
| 传 `const std::vector<T>&` 后存起来 | 悬垂 | 需要持有就拷贝或转移 |

**对象切片**：派生类按值赋给基类对象，派生部分被切掉，且**不报错**。

```cpp
void handle(Shape s);           // ✗ 传 Derived 进来会被切片
void handle(const Shape &s);    // ✓ 多态必须传引用/指针
```

多态基类必须有虚析构（`-Wnon-virtual-dtor` 会提醒）：

```cpp
struct Shape {
    virtual ~Shape() = default;
    virtual double area() const = 0;
};
```

---

## 七、ABI 与跨模块边界（DLL / .so 场景最容易出事）

### 跨模块只能传 C ABI

```cpp
// 库的头文件
#ifdef _WIN32
#  ifdef MYLIB_BUILD
#    define MYLIB_API __declspec(dllexport)
#  else
#    define MYLIB_API __declspec(dllimport)
#  endif
#else
#  define MYLIB_API __attribute__((visibility("default")))
#endif

extern "C" {
MYLIB_API MyHandle *mylib_create(const char *path);   // 不透明句柄
MYLIB_API void mylib_destroy(MyHandle *h);
MYLIB_API int mylib_run(MyHandle *h, const unsigned char *in, size_t in_len,
                        unsigned char *out, size_t out_cap, size_t *out_len);
}
```

`extern "C"` 关掉 name mangling；接口里不能有 `std::string` / `std::vector` / 异常 / 模板——
不同编译器版本对这些的实现不一致，边界另一侧就崩。

### 堆必须同源

Windows 上每个 DLL 和主程序可能各有一份 CRT 堆（`/MT` 静态链接时必然）。
**在 A 里分配、在 B 里释放** 会破坏堆 → 崩溃，且崩点远离病因。

规避方式二选一：
- 全部用 DLL CRT（MSVC `/MD`），且编译器版本尽量一致；
- 或者让分配方也提供释放函数（`mylib_free(buf)`），调用方只负责调。

### name mangling 不稳定

不要在导出符号名里依赖 C++ 签名。GCC 和 MSVC 的 mangling 方案不同，
MSVC 甚至在不同大版本间变过。跨编译器导出 = 必须走 `extern "C"` 或 `.def` 文件。

---

## 八、C 与 C++ 混编的具体做法

### C 头文件被 C++ 包含

```c
/* mylib.h —— 让 C 和 C++ 都能用 */
#ifdef __cplusplus
extern "C" {
#endif

int mylib_init(void);

#ifdef __cplusplus
}
#endif
```

### C++ 调用 C 库

```cpp
extern "C" {
#include <zlib.h>          // C 头文件必须包在 extern "C" 里，否则符号名对不上
}
```

### C 调用 C++ 实现

C++ 侧提供 `extern "C"` 的薄包装层，包装层内部用 C++ 实现，
捕获所有异常转成错误码，绝不让异常穿过 C 栈帧：

```cpp
extern "C" int mylib_parse(const char *s, size_t n) {
    try {
        return parse_impl(s, n);       // 返回 0 成功 / 负值错误码
    } catch (const std::bad_alloc &) {
        return MYLIB_ERR_NOMEM;
    } catch (...) {
        return MYLIB_ERR_INTERNAL;
    }
}
```

### 不要在 C++ 里用 C 宏写控制流

`assert`、`offsetof`、带副作用的宏在 C++ 里同样有坑，但 `= default`、`final`、`override` 这些
关键字可能被同名的老宏撞上（Windows 头文件的 `min`/`max` 宏是经典杀手）：

```cpp
#define NOMINMAX                 // 包含 <windows.h> 之前，否则 std::min/max 全废
#include <windows.h>
```

---

## 九、性能相关的常识（别过早优化，但也别写反了）

| 做法 | 原因 |
| --- | --- |
| 大对象按 `const &` 传，小对象（≤16 字节）按值 | 拷贝开销与寄存器传递的权衡 |
| 返回局部对象直接 `return obj;` | NRVO 免拷贝；**不要** `return std::move(obj);`（会阻止 NRVO） |
| 已知大小时 `reserve` | 避免反复 realloc + 拷贝 |
| 优先 `emplace_back` 而非 `push_back(T(...))` | 省一次移动 |
| 热路径上的虚调用要算清楚 | 间接跳转 + 无法内联；三五个实现时考虑 `variant` + `visit` |
| 异常是零成本（不抛时） | x86-64 用表驱动展开，但会增大二进制 |
| `std::string` 的 SSO | 短串不分配；但别把它当性能保证 |

---

## 十、C++ 门禁命令（本机实测）

```bash
g++ -std=c++20 -O2 -g \
  -Wall -Wextra -Wpedantic -Werror \
  -Wshadow -Wconversion -Wsign-conversion \
  -Wnon-virtual-dtor -Woverloaded-virtual -Wextra-semi \
  -Wold-style-cast -Wcast-qual -Wcast-align=strict -Wdouble-promotion \
  -Wformat=2 -Wnull-dereference -Wuseless-cast \
  -Wredundant-decls -Wimplicit-fallthrough \
  -fstack-protector-strong \
  -c src.cpp -o src.o
```

**注意这些 C 专用的警告在 C++ 下不适用，会直接报参数错误**：
`-Wstrict-prototypes`、-Wmissing-prototypes`、`-Wmissing-declarations`、`-Wold-style-definition`、
`-Wbad-function-cast`。`scripts/check-c.*` 会按扩展名自动选用对应的参数集。

MSVC：

```
cl /nologo /std:c++20 /W4 /permissive- /utf-8 /EHsc /Zc:preprocessor /GS /guard:cf /c src.cpp
```

`/EHsc` 必须有，否则 `try/catch` 直接报 C4530。

---

## 十一、C++ 高频坑 Top 10

1. **返回局部变量的引用/指针/`string_view`** → 悬垂。函数返回引用时，被引用对象必须活得比调用方。
2. **`auto` 吃掉 `const` 与引用** → `auto s = obj.name();` 是拷贝；要引用写 `auto &` / `const auto &`。
3. **`std::move` 之后继续用源对象** → 对象处于"有效但未指定"状态，只能析构或重新赋值。
4. **异常穿过析构/`noexcept` 函数** → `std::terminate`。
5. **静态初始化顺序**（不同 TU 的全局对象互相依赖）→ 改成函数内 `static`（C++11 起线程安全）。
6. **`shared_ptr` 循环引用** → 泄漏。用 `weak_ptr` 打断。
7. **头文件里定义非 inline 函数** → 多重定义。
8. **模板特化写在 `.cpp` 里** → 别的 TU 看不见，链接期才报 undefined。
9. **跨 DLL 传 STL 容器** → 不同 CRT/版本 → 堆破坏或迭代器失效。走 C ABI。
10. **有符号整数溢出** → 在 C++ 里同样是 UB，且优化器比 C 更激进。用 `-ftrapv` 调试或显式检查。

---

## 十二、C++ 代码自审清单（在 `review.md` 的通用清单之外，额外加这些）

- [ ] 有没有裸 `new` / `delete` / `malloc` / `free`？
- [ ] 手写析构的类，五个特殊成员函数想清楚了吗（`= delete` 也是想清楚）？
- [ ] 多态基类的析构是 `virtual` 吗？
- [ ] 有没有 `const_cast` 去掉的 `const` 又被写回？（那是 UB）
- [ ] 有没有返回悬垂引用/`string_view`/迭代器？
- [ ] 容器在遍历中被修改了吗？
- [ ] `shared_ptr` 有没有循环？
- [ ] 导出接口是不是纯 C ABI？
- [ ] 分配与释放在同一模块/同一 CRT 吗？
- [ ] 异常能穿过 `extern "C"` 边界吗？（不能）
- [ ] 头文件里有没有 `using namespace`、非 inline 定义、非 `constexpr` 全局对象？
- [ ] `[[nodiscard]]` 覆盖了所有可能被忽略的返回值吗？
