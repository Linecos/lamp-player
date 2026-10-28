#requires -Version 5.1
<#
.SYNOPSIS
    提交前本地自检：等价于 CI 跑的那几项。

.DESCRIPTION
    Dart 侧：flutter analyze / flutter test / dart format --set-exit-if-changed
    Rust 侧：cargo fmt --check / cargo clippy -D warnings / cargo test
    任意一项失败时脚本以非 0 退出，并汇总失败项。

.PARAMETER SkipRust
    只查 Dart 侧。

.PARAMETER SkipFlutter
    只查 Rust 侧。

.PARAMETER RustupHome
    Rust 装在非默认位置时传入，例如 E:\rust\rustup。

.PARAMETER CargoHome
    同上，例如 E:\rust\cargo。

.EXAMPLE
    .\scripts\check.ps1

.EXAMPLE
    .\scripts\check.ps1 -SkipRust
#>
[CmdletBinding()]
param(
    [switch]$SkipRust,
    [switch]$SkipFlutter,
    [string]$RustupHome,
    [string]$CargoHome
)

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

if ($RustupHome) { $env:RUSTUP_HOME = $RustupHome }
if ($CargoHome) {
    $env:CARGO_HOME = $CargoHome
    $env:Path = (Join-Path $CargoHome 'bin') + ';' + $env:Path
}

# 系统代理拦 localhost 时 flutter test 会报 WebSocket upgrade 失败：
# 光设 no_proxy 不够，必须把代理变量本身清掉（CI 上没有这些变量）。
foreach ($name in 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy') {
    Remove-Item ("env:" + $name) -ErrorAction SilentlyContinue
}
$env:no_proxy = 'localhost,127.0.0.1,::1'

$failed = New-Object System.Collections.ArrayList

function Show-Result($Name, $Code) {
    if ($Code -ne 0) {
        Write-Host "  FAIL  $Name (exit $Code)" -ForegroundColor Red
        [void]$failed.Add($Name)
    }
    else {
        Write-Host "  PASS  $Name" -ForegroundColor Green
    }
}

Write-Host ''
Write-Host 'Lamp Player 本地检查' -ForegroundColor White
Write-Host '-------------------' -ForegroundColor DarkGray

Write-Host ''
Write-Host '==> FRB 版本三处一致' -ForegroundColor Cyan
# Cargo.toml / pubspec.yaml / ci.yml 的 FRB_VERSION 必须同版本：不一致时
# codegen 生成的代码会和运行时 crate 对不上，CI 的 frb 一致性 job 才会报错，
# 而那时通常已经推上去了。这里提前拦住。
$frbSpecs = @(
    @{ File = 'rust/Cargo.toml'; Pattern = 'flutter_rust_bridge\s*=\s*"=([\d.]+)"' },
    @{ File = 'pubspec.yaml'; Pattern = 'flutter_rust_bridge:\s*([\d.]+)' },
    @{ File = '.github/workflows/ci.yml'; Pattern = 'FRB_VERSION:\s*"([\d.]+)"' }
)
$frbFound = @{}
foreach ($spec in $frbSpecs) {
    $hit = Select-String -Path (Join-Path $root $spec.File) -Pattern $spec.Pattern |
        Select-Object -First 1
    $frbFound[$spec.File] = if ($hit) { $hit.Matches[0].Groups[1].Value } else { '' }
}
$frbUnique = @($frbFound.Values | Where-Object { $_ -ne '' } | Sort-Object -Unique)
if (($frbFound.Values -contains '') -or ($frbUnique.Count -ne 1)) {
    foreach ($key in $frbFound.Keys) {
        $value = if ($frbFound[$key]) { $frbFound[$key] } else { '未找到' }
        Write-Host ('    ' + $key + ' = ' + $value) -ForegroundColor Yellow
    }
    [void]$failed.Add('FRB 版本一致')
} else {
    Write-Host ('    三处都是 ' + $frbUnique[0]) -ForegroundColor DarkGray
}

if (-not $SkipFlutter) {
    Write-Host ''
    Write-Host '==> flutter analyze' -ForegroundColor Cyan
    flutter analyze
    Show-Result 'flutter analyze' $LASTEXITCODE

    Write-Host ''
    Write-Host '==> flutter test' -ForegroundColor Cyan
    flutter test
    Show-Result 'flutter test' $LASTEXITCODE

    Write-Host ''
    Write-Host '==> dart format（只检查，不改文件）' -ForegroundColor Cyan
    dart format --output=none --set-exit-if-changed lib test integration_test
    Show-Result 'dart format' $LASTEXITCODE
}

if (-not $SkipRust) {
    Push-Location (Join-Path $root 'rust')
    try {
        Write-Host ''
        Write-Host '==> cargo fmt --check' -ForegroundColor Cyan
        cargo fmt --check
        Show-Result 'cargo fmt' $LASTEXITCODE

        Write-Host ''
        Write-Host '==> cargo clippy -D warnings' -ForegroundColor Cyan
        cargo clippy --all-targets -- -D warnings
        Show-Result 'cargo clippy' $LASTEXITCODE

        Write-Host ''
        Write-Host '==> cargo test' -ForegroundColor Cyan
        cargo test
        Show-Result 'cargo test' $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
}

Write-Host ''
if ($failed.Count -eq 0) {
    Write-Host '全部通过，可以提交了。' -ForegroundColor Green
    Write-Host '（别忘了：改了 Rust API 要跑 flutter_rust_bridge_codegen generate）' -ForegroundColor DarkGray
    exit 0
}

Write-Host ('有 ' + $failed.Count + ' 项未通过：') -ForegroundColor Red
foreach ($item in $failed) { Write-Host ('  - ' + $item) -ForegroundColor Red }
exit 1
