#requires -Version 5.1
<#
.SYNOPSIS
    一次性准备 Lamp Player 的本地开发环境。

.DESCRIPTION
    依次完成：工具链检查 -> flutter pub get -> cargo fetch -> 下载 BASS。
    可重复执行，已就绪的步骤会自动跳过。

.PARAMETER SkipBass
    不下载 BASS（只想编译、暂不调试播放时用）。

.PARAMETER SkipRust
    不碰 Rust 侧（只改 Dart UI 时用）。

.PARAMETER RustupHome
    Rust 装在非默认位置时传入，例如 E:\rust\rustup。

.PARAMETER CargoHome
    同上，例如 E:\rust\cargo。

.EXAMPLE
    .\scripts\bootstrap.ps1

.EXAMPLE
    .\scripts\bootstrap.ps1 -RustupHome E:\rust\rustup -CargoHome E:\rust\cargo
#>
[CmdletBinding()]
param(
    [switch]$SkipBass,
    [switch]$SkipRust,
    [string]$RustupHome,
    [string]$CargoHome
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Write-Step($Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok($Message) { Write-Host "  OK  $Message" -ForegroundColor Green }
function Write-Note($Message) { Write-Host "  !!  $Message" -ForegroundColor Yellow }

# Rust 装到非默认目录时必须显式指定，否则 cargo 找不到工具链
if ($RustupHome) { $env:RUSTUP_HOME = $RustupHome }
if ($CargoHome) {
    $env:CARGO_HOME = $CargoHome
    $env:Path = (Join-Path $CargoHome 'bin') + ';' + $env:Path
}

Write-Host ''
Write-Host 'Lamp Player 环境准备' -ForegroundColor White
Write-Host '--------------------' -ForegroundColor DarkGray

# 1. 工具链检查
Write-Step '检查工具链'

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw 'Flutter 不在 PATH 里。装好 Flutter 3.47+ 后把 <flutter>\bin 加入 PATH。'
}
Write-Ok ('flutter ' + (flutter --version | Select-Object -First 1))

if (-not $SkipRust) {
    if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
        throw 'cargo 不在 PATH 里。装好 Rust（stable-msvc），或传 -CargoHome 指定位置。'
    }
    Write-Ok ((cargo --version) + ' / ' + (rustc --version))
}

# 2. Dart 依赖
Write-Step 'flutter pub get'
flutter pub get
if ($LASTEXITCODE -ne 0) { throw 'flutter pub get 失败，见上面的输出。' }
Write-Ok 'Dart 依赖就绪'

# 3. Rust 依赖预热
if (-not $SkipRust) {
    Write-Step 'cargo fetch（预热 Rust 依赖，首次较慢）'
    Push-Location (Join-Path $root 'rust')
    try {
        cargo fetch
        if ($LASTEXITCODE -ne 0) { throw 'cargo fetch 失败，检查网络或 Rust 工具链。' }
    }
    finally {
        Pop-Location
    }
    Write-Ok 'Rust 依赖就绪'
}

# 4. BASS
if ($SkipBass) {
    Write-Note '已跳过 BASS 下载（-SkipBass）。播放相关功能将不可用。'
}
else {
    $dll = Join-Path $root 'third_party\bass\windows\x64\bass.dll'
    if (Test-Path $dll) {
        Write-Ok 'bass.dll 已存在'
    }
    else {
        Write-Step '下载 BASS 2.4 SDK'
        & (Join-Path $PSScriptRoot 'setup-bass.ps1')
        if ($LASTEXITCODE -ne 0) { throw 'BASS 下载失败，可稍后手动执行 scripts\setup-bass.ps1。' }
    }

    # WASAPI 独占输出要额外的 addon，缺了只影响独占，不影响共享播放
    $wasapi = Join-Path $root 'third_party\bass\windows\x64\basswasapi.dll'
    if (Test-Path $wasapi) {
        Write-Ok 'WASAPI 输出扩展已存在'
    }
    else {
        Write-Step '下载 BASS 输出扩展（basswasapi / bassmix）'
        & (Join-Path $PSScriptRoot 'setup-bass-output.ps1')
        if ($LASTEXITCODE -ne 0) {
            Write-Note '输出扩展未就绪，独占输出不可用（共享播放不受影响）。可稍后手动执行 scripts\setup-bass-output.ps1。'
        }
    }
}

Write-Host ''
Write-Host '准备工作完成。' -ForegroundColor Green
Write-Host ''
Write-Host '下一步：'
Write-Host '  flutter run -d windows         # 启动应用'
Write-Host '  .\scripts\check.ps1            # 提交前跑一遍全套检查（等价 CI）'
Write-Host ''
Write-Host '参与方式见 CONTRIBUTING.md，任务清单见 docs/ROADMAP.md。'
