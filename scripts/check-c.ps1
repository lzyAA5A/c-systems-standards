<#
.SYNOPSIS
    C / C++ 编译门禁：按高警告档逐文件编译，任何警告即失败。

.DESCRIPTION
    递归展开目录里的 .c / .cpp / .cc / .cxx，按扩展名自动选择语言与编译器
    （.c → gcc/-std=c17，C++ → g++/-std=c++20；MSVC 侧同一套 cl，只换标准开关），
    逐文件报 PASS/FAIL。退出码：0 = 全部通过；1 = 有文件失败；2 = 参数/环境问题。

.PARAMETER Path
    文件或目录，可给多个。目录会递归查找源文件。

.PARAMETER Toolchain
    gcc（默认）或 msvc。gcc 通道下 C 用 gcc、C++ 用 g++。

.PARAMETER Analyzer
    gcc 下追加 -fanalyzer（GCC 静态分析，慢但能抓栈溢出等）；msvc 下追加 /analyze。

.PARAMETER Include
    额外的 include 目录（可多个）。每个源文件所在目录会自动加入。

.PARAMETER Extra
    额外的编译器参数（可多个），原样追加。

.PARAMETER NoWerror
    只报警告不失败（用于存量代码摸底）。

.PARAMETER Std
    覆盖语言标准。留空则用默认（C17 / C++20）。例如 -Std c++23、-Std c11。

.EXAMPLE
    .\check-c.ps1 -Path .\src
    .\check-c.ps1 -Path .\src -Analyzer
    .\check-c.ps1 -Path .\src -Toolchain msvc
    .\check-c.ps1 -Path .\src -Std c++23
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string[]] $Path,

    [ValidateSet('gcc', 'msvc')]
    [string] $Toolchain = 'gcc',

    [switch] $Analyzer,
    [string[]] $Include = @(),
    [string[]] $Extra = @(),
    [switch] $NoWerror,
    [string] $Std = ''
)

$ErrorActionPreference = 'Continue'

# ---------- 语言判定 ----------
function Test-IsCpp([string] $file) {
    $ext = [System.IO.Path]::GetExtension($file).ToLowerInvariant()
    return ($ext -eq '.cpp' -or $ext -eq '.cc' -or $ext -eq '.cxx' -or $ext -eq '.c++')
}
function Test-IsCSource([string] $file) {
    if (Test-IsCpp $file) { return $true }
    return ([System.IO.Path]::GetExtension($file).ToLowerInvariant() -eq '.c')
}

# ---------- 收集源文件 ----------
$files = New-Object 'System.Collections.Generic.List[string]'
foreach ($p in $Path) {
    if (-not (Test-Path -LiteralPath $p)) {
        Write-Host "[skip] 不存在：$p" -ForegroundColor DarkYellow
        continue
    }
    $item = Get-Item -LiteralPath $p
    if ($item.PSIsContainer) {
        # 跳过构建产物与依赖目录，避免把生成源码也算进门禁
        Get-ChildItem -LiteralPath $item.FullName -Recurse -File |
            Where-Object {
                (Test-IsCSource $_.FullName) -and
                $_.FullName -notmatch '[\\/](build|\.git|out|target|\.cache|node_modules|third_party|cmake-build-[^\\/]+)[\\/]'
            } |
            Sort-Object FullName | ForEach-Object { $files.Add($_.FullName) }
    }
    elseif (Test-IsCSource $item.FullName) {
        $files.Add($item.FullName)
    }
    else {
        Write-Host "[skip] 不是 C/C++ 源文件：$p" -ForegroundColor DarkYellow
    }
}
$targets = @($files | Select-Object -Unique)
if ($targets.Count -eq 0) {
    Write-Host "没有找到 .c / .cpp 文件。" -ForegroundColor Red
    exit 2
}

# ---------- 临时目录 ----------
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("cgate-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null

# ---------- 参数集 ----------
# C 与 C++ 共用的高价值警告
$gccWarnCommon = @(
    '-O2', '-g'
    '-Wall', '-Wextra', '-Wpedantic'
    '-Wshadow', '-Wconversion', '-Wsign-conversion', '-Wfloat-conversion'
    '-Wcast-qual', '-Wcast-align=strict', '-Wwrite-strings'
    '-Wpointer-arith'
    '-Wundef', '-Wvla', '-Walloca', '-Walloc-zero', '-Wdouble-promotion'
    '-Wformat=2', '-Wnull-dereference'
    '-Wduplicated-cond', '-Wlogical-op', '-Wswitch-default'
    '-Wredundant-decls', '-Wimplicit-fallthrough'
    '-fstack-protector-strong'
)
# 只有 C 才有的警告（C++ 编译时传这些会直接被拒）
$gccWarnCOnly = @(
    '-Wbad-function-cast'
    '-Wstrict-prototypes', '-Wmissing-prototypes', '-Wmissing-declarations'
    '-Wold-style-definition'
)
# 只有 C++ 才有的警告
$gccWarnCppOnly = @(
    '-Wnon-virtual-dtor', '-Woverloaded-virtual', '-Wextra-semi'
    '-Wold-style-cast', '-Wuseless-cast'
)

$msvcWarnCommon = @(
    '/nologo', '/W4', '/permissive-', '/utf-8'
    '/Zc:preprocessor', '/GS', '/guard:cf'
)

$stdC   = if ($Std -and $Std -notmatch '^c\+\+') { $Std } else { 'c17' }
$stdCpp = if ($Std -and $Std -match '^c\+\+')  { $Std } else { 'c++20' }

# ---------- MSVC 环境 ----------
$vcvars = $null
if ($Toolchain -eq 'msvc') {
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
    $patterns = foreach ($r in $roots) {
        foreach ($ver in @('2026', '18', '2022', '17', '2019', '16')) {
            Join-Path $r "Microsoft Visual Studio\$ver\*\VC\Auxiliary\Build\vcvars64.bat"
        }
    }
    foreach ($pat in $patterns) {
        $hit = Get-ChildItem -Path $pat -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { $vcvars = $hit.FullName; break }
    }
    if (-not $vcvars) {
        Write-Host "找不到 vcvars64.bat，无法使用 MSVC。改用 -Toolchain gcc，或安装 VS/BuildTools。" -ForegroundColor Red
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        exit 2
    }
    Write-Host "MSVC 环境：$vcvars" -ForegroundColor DarkGray
    if (-not (Get-Command cl -ErrorAction SilentlyContinue)) {
        # 仅提示：真正调用时会经由 vcvars64 初始化
        Write-Host "（cl 不在当前 PATH，将通过 vcvars64 初始化）" -ForegroundColor DarkGray
    }
}

$nC   = @($targets | Where-Object { -not (Test-IsCpp $_) }).Count
$nCpp = @($targets | Where-Object { Test-IsCpp $_ }).Count
Write-Host ("门禁：{0}  C 文件：{1}  C++ 文件：{2}{3}" -f `
    $Toolchain, $nC, $nCpp, $(if ($Analyzer) { '  (+静态分析)' } else { '' })) -ForegroundColor Cyan

# ---------- 逐文件编译 ----------
$failed = New-Object 'System.Collections.Generic.List[string]'
$warnCount = 0
$idx = 0

foreach ($file in $targets) {
    $idx++
    $name = [System.IO.Path]::GetFileName($file)
    $dir = [System.IO.Path]::GetDirectoryName($file)
    $obj = Join-Path $work ("obj{0}.obj" -f $idx)
    $isCpp = Test-IsCpp $file

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    if ($Toolchain -eq 'gcc') {
        $compiler = if ($isCpp) { 'g++' } else { 'gcc' }
        if (-not (Get-Command $compiler -ErrorAction SilentlyContinue)) {
            Write-Host ("[FAIL] {0}  找不到编译器 {1}" -f $name, $compiler) -ForegroundColor Red
            $failed.Add($file)
            $sw.Stop()
            continue
        }
        $argv = @()
        if ($isCpp) {
            $argv += @("-std=$stdCpp")
            $argv += $gccWarnCommon + $gccWarnCppOnly
        }
        else {
            $argv += @("-std=$stdC")
            $argv += $gccWarnCommon + $gccWarnCOnly
        }
        if (-not $NoWerror) { $argv += '-Werror' }
        if ($Analyzer) { $argv += '-fanalyzer' }
        $argv += @('-I', $dir)
        foreach ($inc in $Include) { $argv += @('-I', (Resolve-Path -LiteralPath $inc).Path) }
        $argv += $Extra
        $argv += @('-c', $file, '-o', $obj)

        $output = & $compiler @argv 2>&1
        $code = $LASTEXITCODE
    }
    else {
        $msvcWarn = @($msvcWarnCommon) +
                    $(if ($isCpp) { @("/std:$stdCpp", '/EHsc') } else { @("/std:$stdC") })
        if (-not $NoWerror) { $msvcWarn += '/WX' }
        if ($Analyzer) { $msvcWarn += '/analyze' }

        $incArgs = "/I`"$dir`""
        foreach ($inc in $Include) { $incArgs += " /I`"$((Resolve-Path -LiteralPath $inc).Path)`"" }
        $extraArgs = ''
        foreach ($e in $Extra) { $extraArgs += " $e" }
        $cmdline = "`"$vcvars`" >nul 2>&1 && cl $($msvcWarn -join ' ') $incArgs$extraArgs /c `"$file`" /Fo`"$obj`""
        $output = & cmd /c $cmdline 2>&1
        $code = $LASTEXITCODE
    }
    $sw.Stop()

    $lines = @($output | ForEach-Object { "$_" } | Where-Object { $_ -match '\S' })
    $real = @($lines | Where-Object { $_ -match '(warning|error|note|错误|警告)\s*[:：C]|\.[ch](pp)?:\d+' })
    $warnCount += @($real | Where-Object { $_ -match 'warning|警告' }).Count

    $tag = if ($isCpp) { 'C++' } else { 'C' }
    if ($code -eq 0) {
        Write-Host ("[PASS] [{0}] {1}  ({2:N1}s)" -f $tag, $name, $sw.Elapsed.TotalSeconds) -ForegroundColor Green
        if ($real.Count -gt 0) {
            $real | Select-Object -First 40 | ForEach-Object { Write-Host "       $_" -ForegroundColor Yellow }
        }
    }
    else {
        Write-Host ("[FAIL] [{0}] {1}  ({2:N1}s)" -f $tag, $name, $sw.Elapsed.TotalSeconds) -ForegroundColor Red
        $real | Select-Object -First 60 | ForEach-Object { Write-Host "       $_" -ForegroundColor Red }
        $failed.Add($file)
    }
}

# ---------- 汇总 ----------
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host ("门禁通过：{0} 个文件（C {1} / C++ {2}），0 错误。" -f $targets.Count, $nC, $nCpp) -ForegroundColor Green
    exit 0
}
Write-Host ("门禁失败：{0}/{1} 个文件未通过。" -f $failed.Count, $targets.Count) -ForegroundColor Red
$failed | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
exit 1
