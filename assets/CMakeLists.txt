# 跨平台 C 工程骨架 —— 复制后改 project() 名、源文件列表即可。
# 要点：目标级选项（不污染第三方）、严格标准、警告即错误、ABI 断言。

cmake_minimum_required(VERSION 3.20)
project(demo LANGUAGES C)

set(CMAKE_C_STANDARD 17)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)          # 用 -std=c17，而不是 -std=gnu17

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE RelWithDebInfo CACHE STRING "" FORCE)
endif()

# ---------- 统一的警告档（INTERFACE 目标：只影响链接它的目标） ----------
add_library(demo_warnings INTERFACE)
add_library(demo::warnings ALIAS demo_warnings)

if(MSVC)
    target_compile_options(demo_warnings INTERFACE
        /W4 /permissive- /utf-8 /Zc:preprocessor /GS /guard:cf
        $<$<CONFIG:Release>:/O2>
        $<$<CONFIG:Debug>:/Od>
    )
    # /WX 让警告变成错误；历史代码多时先注释掉，逐步收紧
    target_compile_options(demo_warnings INTERFACE /WX)
else()
    target_compile_options(demo_warnings INTERFACE
        -Wall -Wextra -Wpedantic -Werror
        -Wshadow -Wconversion -Wsign-conversion -Wfloat-conversion
        -Wcast-qual -Wcast-align=strict -Wwrite-strings
        -Wstrict-prototypes -Wmissing-prototypes -Wmissing-declarations
        -Wold-style-definition -Wundef -Wvla -Wdouble-promotion
        -Wformat=2 -Wnull-dereference -Wimplicit-fallthrough
        -fstack-protector-strong
        $<$<PLATFORM_ID:Linux>:-D_FORTIFY_SOURCE=2>
    )
endif()

# ---------- 核心库 ----------
add_library(demo_core
    src/module.c
)
add_library(demo::core ALIAS demo_core)

target_include_directories(demo_core
    PUBLIC  ${CMAKE_CURRENT_SOURCE_DIR}/include
    PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src
)
target_link_libraries(demo_core PRIVATE demo_warnings)

# 共享库时导出符号：Windows 用 __declspec，Linux 靠 -fvisibility=hidden
# add_library(demo_core SHARED src/module.c)
# target_compile_definitions(demo_core PRIVATE DEMO_BUILD=1)
# set_target_properties(demo_core PROPERTIES
#     C_VISIBILITY_PRESET hidden
#     WINDOWS_EXPORT_ALL_SYMBOLS OFF)

# ---------- 第三方代码：SYSTEM 头 + 单独 target，不吃本工程警告档 ----------
# add_subdirectory(third_party/cjson EXCLUDE_FROM_ALL)
# target_include_directories(demo_core SYSTEM PRIVATE third_party/cjson)

# ---------- 测试（每个测试文件是独立可执行，返回非 0 即失败） ----------
enable_testing()
# add_executable(test_module tests/test_module.c)
# target_link_libraries(test_module PRIVATE demo_core)
# add_test(NAME module COMMAND test_module)

# ---------- 可选：GCC 静态分析档 ----------
# cmake -B build -DCMAKE_C_FLAGS="-fanalyzer"
