#requires -Version 5.1
<#
.SYNOPSIS
    下载 BASS 音频格式插件，补齐 scanner.rs 中八种格式的播放能力。
    （wma 不参与扫描，basswma 插件只为将来播放保留。）

.DESCRIPTION
    bass.dll 本体只解 mp3 / ogg / wav / aiff，其余格式由 un4seen 的 addon DLL 解码，
    运行时用 BASS_PluginLoad 注册即可，Rust 侧解码逻辑无需改动。

    本脚本只负责把 DLL 放进 third_party/bass/windows/{x64,x86}/，
    拷到构建产物目录由 windows/CMakeLists.txt 的 install 规则完成。

.PARAMETER Dest
    目标根目录，默认 <仓库根>\third_party\bass\windows

.PARAMETER Force
    DLL 已存在时也重新下载。

.PARAMETER SkipX86
    只处理 x64。

.PARAMETER Proxy
    走指定代理，例如 -Proxy http://127.0.0.1:10808。

.PARAMETER NoProxy
    忽略代理直连，用于 CI/沙箱注入了坏代理的场景。

.EXAMPLE
    .\scripts\setup-bass-plugins.ps1 -NoProxy
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

Add-Type -AssemblyName System.IO.Compression.FileSystem

# 5.1 默认可能不开 TLS 1.2，un4seen.com 只接受 TLS 1.2+
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
catch {
}

# 代理必须显式传参：5.1 的 Invoke-WebRequest 不读 HTTP(S)_PROXY，走 .NET 默认代理
$proxyArgs = @{}
if ($Proxy) {
    $proxyArgs['Proxy'] = $Proxy
    Write-Host "使用代理: $Proxy" -ForegroundColor DarkGray
}
elseif ($NoProxy) {
    if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey('NoProxy')) {
        $proxyArgs['NoProxy'] = $true
    }
    else {
        [System.Net.WebRequest]::DefaultWebProxy = $null
    }
    Write-Host '已忽略代理，直连下载。' -ForegroundColor DarkGray
}

if (-not $Dest) {
    $Dest = Join-Path (Split-Path -Parent $PSScriptRoot) 'third_party\bass\windows'
}

$addons = @(
    [pscustomobject]@{ Name = 'bassflac'; Url = 'https://www.un4seen.com/files/bassflac24.zip';     Formats = 'flac' }
    [pscustomobject]@{ Name = 'bassopus'; Url = 'https://www.un4seen.com/files/bassopus24.zip';     Formats = 'opus' }
    [pscustomobject]@{ Name = 'bass_aac'; Url = 'https://www.un4seen.com/files/z/2/bass_aac24.zip'; Formats = 'm4a / aac' }
    [pscustomobject]@{ Name = 'bassape';  Url = 'https://www.un4seen.com/files/bassape24.zip';      Formats = 'ape' }
    [pscustomobject]@{ Name = 'basswma';  Url = 'https://www.un4seen.com/files/basswma24.zip';      Formats = 'wma' }
)

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

if (-not (Test-Path (Join-Path $Dest 'x64\bass.dll'))) {
    Write-Host ''
    Write-Host '警告：未找到 x64\bass.dll，请先执行 .\scripts\setup-bass.ps1' -ForegroundColor Yellow
}

$null = New-Item -ItemType Directory -Force -Path (Join-Path $Dest 'x64')
if (-not $SkipX86) {
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $Dest 'x86')
}

$results = New-Object System.Collections.ArrayList
$failed = New-Object System.Collections.ArrayList

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

        Invoke-WebRequest -Uri $addon.Url -OutFile $zipPath -UseBasicParsing @proxyArgs
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractDir)

        # 包内结构：x64\<name>.dll、根目录 32 位 <name>.dll、c\<name>.h
        $srcX64 = Join-Path $extractDir "x64\$name.dll"
        if (-not (Test-Path $srcX64)) {
            throw "压缩包内未找到 x64\$name.dll"
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

Write-Host ''
Write-Host '格式覆盖核对（对应 scanner.rs 的 AUDIO_EXTENSIONS）' -ForegroundColor White
Write-Host '--------------------------------------------------' -ForegroundColor DarkGray

$formatRows = foreach ($ext in $expected.Keys) {
    $dll = $expected[$ext]
    $path = Join-Path $Dest "x64\$dll"
    [pscustomobject]@{
        格式 = $ext
        依赖 = $dll
        状态 = if ((Test-Path $path) -and ((Get-Item $path).Length -gt 0)) { '可播放' } else { '缺失' }
    }
}
$formatRows | Format-Table -AutoSize | Out-String | Write-Host

$missing = @($formatRows | Where-Object { $_.状态 -eq '缺失' } | Select-Object -ExpandProperty 格式)

Write-Host ''
if ($failed.Count -gt 0) {
    Write-Host ("有 {0} 个插件下载失败：{1}" -f $failed.Count, ($failed -join ', ')) -ForegroundColor Red
    Write-Host '（上表反映磁盘现状，不是本次运行结果）' -ForegroundColor DarkGray
    Write-Host '可重试：.\scripts\setup-bass-plugins.ps1 -Force' -ForegroundColor DarkGray
    exit 1
}

if ($missing.Count -gt 0) {
    Write-Host ("以下格式仍无法播放：{0}" -f ($missing -join ', ')) -ForegroundColor Yellow
    Write-Host '若是 bass.dll 缺失，请先运行 .\scripts\setup-bass.ps1' -ForegroundColor Yellow
    exit 1
}

Write-Host '扫描所需 + 播放插件的依赖 DLL 已就位。' -ForegroundColor Green
exit 0
