<#
.SYNOPSIS
    C 编译门禁：把 .c 源文件按高警告档逐文件编译，任何警告即失败。

.DESCRIPTION
    递归展开目录里的 *.c，逐个用严格警告档编译成临时 .obj，逐文件报 PASS/FAIL。
    默认 gcc（MSYS2 mingw64 或 PATH 上的 gcc），可选 msvc（自动找 vcvars64.bat）。
    退出码：0 = 全部通过；1 = 有文件失败；2 = 参数/环境问题。

.PARAMETER Path
    文件或目录，可给多个。目录会递归查找 *.c。

.PARAMETER Toolchain
    gcc（默认）或 msvc。

.PARAMETER Analyzer
    gcc 下追加 -fanalyzer（GCC 静态分析，慢但能抓栈溢出等）；msvc 下追加 /analyze。

.PARAMETER Include
    额外的 include 目录（可多个）。每个源文件所在目录会自动加入。

.PARAMETER Extra
    额外的编译器参数（可多个），原样追加。

.PARAMETER NoWerror
    只报警告不失败（用于存量代码摸底）。

.EXAMPLE
    .\check-c.ps1 -Path .\src
    .\check-c.ps1 -Path .\src -Analyzer
    .\check-c.ps1 -Path .\src\a.c,.\src\b.c -Toolchain msvc
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
    [switch] $NoWerror
)

$ErrorActionPreference = 'Continue'

# ---------- 收集源文件 ----------
$files = New-Object 'System.Collections.Generic.List[string]'
foreach ($p in $Path) {
    if (-not (Test-Path -LiteralPath $p)) {
        Write-Host "[skip] 不存在：$p" -ForegroundColor DarkYellow
        continue
    }
    $item = Get-Item -LiteralPath $p
    if ($item.PSIsContainer) {
        # 跳过构建产物与依赖目录，避免把生成的 .c 也算进门禁
        Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Filter *.c |
            Where-Object { $_.FullName -notmatch '[\\/](build|\.git|out|target|\.cache|node_modules|third_party|cmake-build-[^\\/]+)[\\/]' } |
            Sort-Object FullName | ForEach-Object { $files.Add($_.FullName) }
    }
    elseif ($item.Extension -eq '.c') {
        $files.Add($item.FullName)
    }
    else {
        Write-Host "[skip] 不是 .c 文件：$p" -ForegroundColor DarkYellow
    }
}
$targets = @($files | Select-Object -Unique)
if ($targets.Count -eq 0) {
    Write-Host "没有找到 .c 文件。" -ForegroundColor Red
    exit 2
}

# ---------- 临时目录 ----------
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("cgate-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null

# ---------- 参数集 ----------
$gccWarn = @(
    '-std=c17', '-O2', '-g'
    '-Wall', '-Wextra', '-Wpedantic'
    '-Wshadow', '-Wconversion', '-Wsign-conversion', '-Wfloat-conversion'
    '-Wcast-qual', '-Wcast-align=strict', '-Wwrite-strings'
    '-Wpointer-arith', '-Wbad-function-cast'
    '-Wstrict-prototypes', '-Wmissing-prototypes', '-Wmissing-declarations'
    '-Wold-style-definition'
    '-Wundef', '-Wvla', '-Walloca', '-Walloc-zero', '-Wdouble-promotion'
    '-Wformat=2', '-Wnull-dereference'
    '-Wduplicated-cond', '-Wlogical-op', '-Wswitch-default'
    '-Wredundant-decls', '-Wimplicit-fallthrough'
    '-fstack-protector-strong'
)
if (-not $NoWerror) { $gccWarn += '-Werror' }
if ($Analyzer) { $gccWarn += '-fanalyzer' }

$msvcWarn = @(
    '/nologo', '/std:c17', '/W4', '/permissive-', '/utf-8'
    '/Zc:preprocessor', '/GS', '/guard:cf'
)
if (-not $NoWerror) { $msvcWarn += '/WX' }
if ($Analyzer) { $msvcWarn += '/analyze' }

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
}

Write-Host ("门禁：{0}  文件数：{1}{2}" -f $Toolchain, $targets.Count, $(if ($Analyzer) { '  (+静态分析)' } else { '' })) -ForegroundColor Cyan

# ---------- 逐文件编译 ----------
$failed = New-Object 'System.Collections.Generic.List[string]'
$warnCount = 0
$idx = 0

foreach ($file in $targets) {
    $idx++
    $name = [System.IO.Path]::GetFileName($file)
    $dir = [System.IO.Path]::GetDirectoryName($file)
    $obj = Join-Path $work ("obj{0}.obj" -f $idx)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    if ($Toolchain -eq 'gcc') {
        $argv = @($gccWarn) + @('-I', $dir)
        foreach ($inc in $Include) { $argv += @('-I', (Resolve-Path -LiteralPath $inc).Path) }
        $argv += $Extra
        $argv += @('-c', $file, '-o', $obj)
        $output = & gcc @argv 2>&1
        $code = $LASTEXITCODE
    }
    else {
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
    $real = @($lines | Where-Object { $_ -match '(warning|error|note|错误|警告)\s*[:：C]|\.c:\d+' })
    $warnCount += @($real | Where-Object { $_ -match 'warning|警告' }).Count

    if ($code -eq 0) {
        Write-Host ("[PASS] {0}  ({1:N1}s)" -f $name, $sw.Elapsed.TotalSeconds) -ForegroundColor Green
        if ($real.Count -gt 0) {
            $real | Select-Object -First 40 | ForEach-Object { Write-Host "       $_" -ForegroundColor Yellow }
        }
    }
    else {
        Write-Host ("[FAIL] {0}  ({1:N1}s)" -f $name, $sw.Elapsed.TotalSeconds) -ForegroundColor Red
        $real | Select-Object -First 60 | ForEach-Object { Write-Host "       $_" -ForegroundColor Red }
        $failed.Add($file)
    }
}

# ---------- 汇总 ----------
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host ("门禁通过：{0} 个文件，0 错误。" -f $targets.Count) -ForegroundColor Green
    exit 0
}
Write-Host ("门禁失败：{0}/{1} 个文件未通过。" -f $failed.Count, $targets.Count) -ForegroundColor Red
$failed | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
exit 1
