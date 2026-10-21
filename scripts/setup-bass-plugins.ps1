#requires -Version 5.1
<#
.SYNOPSIS
    下载 BASS 音频格式插件（addon），补齐 scanner.rs 中九种格式的播放能力。

.DESCRIPTION
    BASS 本体（bass.dll）只能解 MP3 / OGG / WAV / AIFF。
    其余格式由 un4seen 提供的独立 addon DLL 完成解码，运行时用 BASS_PluginLoad 注册即可，
    Rust 侧的解码逻辑一行都不用改 —— 这是本脚本存在的意义。

    与 scanner.rs 的 AUDIO_EXTENSIONS 严格对齐：
        mp3  wav  ogg          -> bass.dll        （本体，由 setup-bass.ps1 下载）
        flac                   -> bassflac.dll
        opus                   -> bassopus.dll
        m4a  aac               -> bass_aac.dll
        ape                    -> bassape.dll
        wma                    -> basswma.dll

    本脚本只负责把 DLL 放进 third_party/bass/windows/{x64,x86}/，
    **不**负责拷到构建产物目录；那一步由 windows/runner/CMakeLists.txt 的 POST_BUILD 完成。

    特性：
    - 幂等：已存在的 DLL 默认跳过，加 -Force 可强制重新下载
    - 容错：单个插件下载失败**不会**中断整体，最后汇总失败列表并以非 0 退出
    - 校验：拷贝后检查文件大小，0 字节视为失败（防半截文件）

.PARAMETER Dest
    目标根目录，默认 <仓库根>\third_party\bass\windows
    （即 bass.dll 所在目录，插件与 bass.dll 同级摆放）

.PARAMETER Force
    即使 DLL 已存在也重新下载覆盖。

.PARAMETER SkipX86
    只处理 x64，不下 32 位 DLL（默认 x86 也一并保留，供备用/交叉构建）。

.PARAMETER Proxy
    走代理下载，例如 -Proxy http://127.0.0.1:10808

.PARAMETER NoProxy
    清空 HTTP(S)_PROXY 环境变量后再下载（某些 CI/沙箱会注入坏代理，导致 503）。

.EXAMPLE
    .\scripts\setup-bass-plugins.ps1

.EXAMPLE
    .\scripts\setup-bass-plugins.ps1 -Force -NoProxy

.EXAMPLE
    .\scripts\setup-bass-plugins.ps1 -Proxy http://127.0.0.1:10808
#>
[CmdletBinding()]
param(
    [string] $Dest,
    [switch] $Force,
    [switch] $SkipX86,
    [string] $Proxy,
    [switch] $NoProxy
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# 用 .NET 的 ZipFile 解压：比 Expand-Archive 快，且不刷进度条污染输出
Add-Type -AssemblyName System.IO.Compression.FileSystem

if (-not $Dest) {
    $Dest = Join-Path (Split-Path -Parent $PSScriptRoot) 'third_party\bass\windows'
}

if ($NoProxy) {
    $env:HTTP_PROXY = ''; $env:HTTPS_PROXY = ''
    $env:http_proxy = ''; $env:https_proxy = ''
    Write-Host '已清空代理环境变量，直连下载。' -ForegroundColor DarkGray
}
elseif ($Proxy) {
    $env:HTTP_PROXY = $Proxy; $env:HTTPS_PROXY = $Proxy
    $env:http_proxy = $Proxy; $env:https_proxy = $Proxy
    Write-Host "使用代理: $Proxy" -ForegroundColor DarkGray
}

# 插件清单：Name 同时是 DLL 文件名（不含扩展名）与压缩包内的相对路径
# Formats 只用于最后的可读汇报
$addons = @(
    [pscustomobject]@{ Name = 'bassflac'; Url = 'https://www.un4seen.com/files/bassflac24.zip';        Formats = 'flac' }
    [pscustomobject]@{ Name = 'bassopus'; Url = 'https://www.un4seen.com/files/bassopus24.zip';        Formats = 'opus' }
    [pscustomobject]@{ Name = 'bass_aac'; Url = 'https://www.un4seen.com/files/z/2/bass_aac24.zip';    Formats = 'm4a / aac' }
    [pscustomobject]@{ Name = 'bassape';  Url = 'https://www.un4seen.com/files/bassape24.zip';         Formats = 'ape' }
    [pscustomobject]@{ Name = 'basswma';  Url = 'https://www.un4seen.com/files/basswma24.zip';         Formats = 'wma' }
)

# scanner.rs 中九种格式 -> 需要的 DLL（bass.dll 为内置）
$expected = [ordered]@{
    'mp3'  = 'bass.dll'
    'wav'  = 'bass.dll'
    'ogg'  = 'bass.dll'
    'flac' = 'bassflac.dll'
    'opus' = 'bassopus.dll'
    'm4a'  = 'bass_aac.dll'
    'aac'  = 'bass_aac.dll'
    'ape'  = 'bassape.dll'
    'wma'  = 'basswma.dll'
}

Write-Host ''
Write-Host 'BASS 格式插件安装' -ForegroundColor White
Write-Host '-----------------' -ForegroundColor DarkGray
Write-Host "目标目录: $Dest"

# 前置检查：bass.dll 必须已经存在，否则装了插件也没用
$baseDll = Join-Path $Dest 'x64\bass.dll'
if (-not (Test-Path $baseDll)) {
    Write-Host ''
    Write-Host '警告：未找到 x64\bass.dll。' -ForegroundColor Yellow
    Write-Host '      请先执行 .\scripts\setup-bass.ps1 下载 BASS 本体，再运行本脚本。' -ForegroundColor Yellow
}

$null = New-Item -ItemType Directory -Force -Path (Join-Path $Dest 'x64')
if (-not $SkipX86) {
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $Dest 'x86')
}

$results = New-Object System.Collections.ArrayList
$failed  = New-Object System.Collections.ArrayList

foreach ($addon in $addons) {
    $name = $addon.Name
    $x64Target = Join-Path $Dest "x64\$name.dll"

    if ((Test-Path $x64Target) -and (-not $Force)) {
        $size = [math]::Round((Get-Item $x64Target).Length / 1KB, 1)
        Write-Host ("  SKIP  {0,-10} 已存在 ({1} KB)" -f "$name.dll", $size) -ForegroundColor DarkGray
        [void]$results.Add([pscustomobject]@{
            Dll = "$name.dll"; Formats = $addon.Formats; Status = '已存在'; SizeKB = $size
        })
        continue
    }

    Write-Host ("  GET   {0,-10} <- {1}" -f "$name.dll", $addon.Url) -ForegroundColor Cyan

    $zipPath = Join-Path $env:TEMP "$name.zip"
    $extractDir = Join-Path $env:TEMP "bass-addon-$name"

    try {
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
        if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }

        Invoke-WebRequest -Uri $addon.Url -OutFile $zipPath -UseBasicParsing
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractDir)

        # 包里统一是 x64\<name>.dll 与根目录的 32 位 <name>.dll，头文件在 c\<name>.h
        $srcX64 = Join-Path $extractDir "x64\$name.dll"
        if (-not (Test-Path $srcX64)) {
            throw "压缩包内未找到 x64\$name.dll（结构可能变了，请检查 $($addon.Url)）"
        }

        Copy-Item $srcX64 $x64Target -Force
        if ((Get-Item $x64Target).Length -le 0) {
            throw "拷贝后文件为 0 字节: $x64Target"
        }

        if (-not $SkipX86) {
            $srcX86 = Join-Path $extractDir "$name.dll"
            if (Test-Path $srcX86) {
                Copy-Item $srcX86 (Join-Path $Dest "x86\$name.dll") -Force
            }
        }

        # 头文件留在根目录，供 Rust FFI 对照参考（与 setup-bass.ps1 摆法一致）
        $srcHeader = Join-Path $extractDir "c\$name.h"
        if (Test-Path $srcHeader) {
            Copy-Item $srcHeader (Join-Path $Dest "$name.h") -Force
        }

        $size = [math]::Round((Get-Item $x64Target).Length / 1KB, 1)
        Write-Host ("  OK    {0,-10} {1} KB" -f "$name.dll", $size) -ForegroundColor Green
        [void]$results.Add([pscustomobject]@{
            Dll = "$name.dll"; Formats = $addon.Formats; Status = '已安装'; SizeKB = $size
        })
    }
    catch {
        Write-Host ("  FAIL  {0,-10} {1}" -f "$name.dll", $_.Exception.Message) -ForegroundColor Red
        [void]$failed.Add("$name.dll")
        [void]$results.Add([pscustomobject]@{
            Dll = "$name.dll"; Formats = $addon.Formats; Status = '失败'; SizeKB = 0
        })
    }
    finally {
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# ---- 汇总：按 scanner.rs 的九种格式逐个核对 ----
Write-Host ''
Write-Host '格式覆盖核对（对应 scanner.rs 的 AUDIO_EXTENSIONS）' -ForegroundColor White
Write-Host '--------------------------------------------------' -ForegroundColor DarkGray

$formatRows = foreach ($ext in $expected.Keys) {
    $dll = $expected[$ext]
    $path = Join-Path $Dest "x64\$dll"
    $ok = (Test-Path $path) -and ((Get-Item $path).Length -gt 0)
    [pscustomobject]@{
        格式  = $ext
        依赖  = $dll
        状态  = if ($ok) { '可播放' } else { '缺失' }
    }
}
$formatRows | Format-Table -AutoSize | Out-String | Write-Host

$missing = @($formatRows | Where-Object { $_.状态 -eq '缺失' } | Select-Object -ExpandProperty 格式)

Write-Host ''
if ($failed.Count -gt 0) {
    Write-Host ("有 {0} 个插件下载失败：{1}" -f $failed.Count, ($failed -join ', ')) -ForegroundColor Red
    Write-Host '可重试：.\scripts\setup-bass-plugins.ps1 -Force' -ForegroundColor DarkGray
    exit 1
}

if ($missing.Count -gt 0) {
    Write-Host ("以下格式仍无法播放：{0}" -f ($missing -join ', ')) -ForegroundColor Yellow
    Write-Host '若是 bass.dll 缺失，请先运行 .\scripts\setup-bass.ps1' -ForegroundColor Yellow
    exit 1
}

Write-Host '全部九种格式的依赖 DLL 已就位。' -ForegroundColor Green
Write-Host '提醒：本脚本只填充 third_party；拷到 exe 目录由 CMake POST_BUILD 负责（见 docs/M2_BASS_PLAYER_PLAN.md PR1）。' -ForegroundColor DarkGray
exit 0
