#requires -Version 5.1
<#
.SYNOPSIS
    下载 BASS 的输出扩展：basswasapi（WASAPI 独占输出）与 bassmix（混音 / 重采样）。

.DESCRIPTION
    bass.dll 自带的是 DirectSound 输出，采样率跟随设备混音格式，无法独占设备。
    要输出独占需要 basswasapi.dll：先用 BASS_Init(0) 只做解码，再用
    BASS_WASAPI_Init + 回调把解码数据推给设备。

    本脚本只负责把 DLL 放进 third_party/bass/windows/{x64,x86}/ 并保留头文件
    （实现里的结构体与常量以头文件为准，不靠猜）。拷到构建产物由
    windows/CMakeLists.txt 的 POST_BUILD 完成。

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
    .\scripts\setup-bass-output.ps1 -NoProxy
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

try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
catch {
}

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
    [pscustomobject]@{
        Name = 'basswasapi'
        Url  = 'https://www.un4seen.com/files/basswasapi24.zip'
        Role = 'WASAPI 独占 / 共享输出'
    }
    [pscustomobject]@{
        Name = 'bassmix'
        Url  = 'https://www.un4seen.com/files/bassmix24.zip'
        Role = '多源混音与采样率转换'
    }
)

Write-Host ''
Write-Host 'BASS 输出扩展安装' -ForegroundColor White
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

$failed = New-Object System.Collections.ArrayList

foreach ($addon in $addons) {
    $name = $addon.Name
    $x64Target = Join-Path $Dest "x64\$name.dll"

    if ((Test-Path $x64Target) -and (-not $Force)) {
        $size = [math]::Round((Get-Item $x64Target).Length / 1KB, 1)
        Write-Host ("  SKIP  {0,-12} 已存在 ({1} KB)" -f "$name.dll", $size) -ForegroundColor DarkGray
        continue
    }

    Write-Host ("  GET   {0,-12} <- {1}" -f "$name.dll", $addon.Url) -ForegroundColor Cyan

    $zipPath = Join-Path $env:TEMP "$name.zip"
    $extractDir = Join-Path $env:TEMP "bass-addon-$name"

    try {
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
        if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }

        Invoke-WebRequest -Uri $addon.Url -OutFile $zipPath -UseBasicParsing @proxyArgs
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractDir)

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
        Write-Host ("  OK    {0,-12} {1} KB  {2}" -f "$name.dll", $size, $addon.Role) -ForegroundColor Green
    }
    catch {
        Write-Host ("  FAIL  {0,-12} {1}" -f "$name.dll", $_.Exception.Message) -ForegroundColor Red
        [void]$failed.Add("$name.dll")
    }
    finally {
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Write-Host ''
Write-Host '磁盘现状' -ForegroundColor White
Write-Host '--------' -ForegroundColor DarkGray
foreach ($addon in $addons) {
    $path = Join-Path $Dest "x64\$($addon.Name).dll"
    $state = if ((Test-Path $path) -and ((Get-Item $path).Length -gt 0)) { '就绪' } else { '缺失' }
    $color = if ($state -eq '就绪') { 'Green' } else { 'Yellow' }
    Write-Host ("  {0,-16} {1}" -f "$($addon.Name).dll", $state) -ForegroundColor $color
}

Write-Host ''
if ($failed.Count -gt 0) {
    Write-Host ("有 {0} 个扩展下载失败：{1}" -f $failed.Count, ($failed -join ', ')) -ForegroundColor Red
    Write-Host '可重试：.\scripts\setup-bass-output.ps1 -Force' -ForegroundColor DarkGray
    exit 1
}

Write-Host '输出扩展就绪。独占输出还需要在设置页打开「独占输出」。' -ForegroundColor Green
