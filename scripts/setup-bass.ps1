# 从 un4seen.com 下载 BASS 2.4 及官方 add-on，并放到 third_party 目录
# 用法: .\scripts\setup-bass.ps1 [-Force] [-SkipHashCheck]
#
# 只装 x64 运行时（桌面端目标）；x86 一并存放备用。
# WMA/AAC 在 Windows Vista/7 以上也可由系统编解码器支持，add-on 只是补充。

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$SkipHashCheck
)

$ErrorActionPreference = 'Stop'

$dest = Join-Path $PSScriptRoot '..\third_party\bass\windows'
$requiredDlls = @('bass.dll', 'bassflac.dll', 'bassopus.dll', 'bassape.dll', 'basswma.dll')

if (-not $Force) {
    $missing = $requiredDlls | Where-Object { -not (Test-Path (Join-Path $dest "x64\$_")) }
    if ($missing.Count -eq 0) {
        Write-Host 'BASS 运行时已齐全，跳过下载（要强制重下用 -Force）。' -ForegroundColor Green
        exit 0
    }
    if ($missing.Count -lt $requiredDlls.Count) {
        Write-Host ('缺少: ' + ($missing -join ', ') + '，重新下载全部。') -ForegroundColor Yellow
    }
}

# 版本与哈希固定，避免下载到被替换的二进制（un4seen 更新后请同步改这里）
$packages = @(
    @{ Name = 'bass'; Url = 'https://www.un4seen.com/files/bass24.zip'; Sha256 = '3A03EC9A33D0F4F9D167660DA51C8BB1432E8977496995455AB137277D69636E' }
    @{ Name = 'bassflac'; Url = 'https://www.un4seen.com/files/bassflac24.zip'; Sha256 = '147280210F62A80E52094E1822E73A16FD3B1A8C9C857C24DCCA7DCFCB4FFA14' }
    @{ Name = 'bassopus'; Url = 'https://www.un4seen.com/files/bassopus24.zip'; Sha256 = '1FB6E033289EA968CA1FD02DEA154A2E5D06BB9C2E33CDEDA277E63084D9AD20' }
    @{ Name = 'bassape'; Url = 'https://www.un4seen.com/files/bassape24.zip'; Sha256 = '39AED2E9AC240253DE0ECA37D261715B85CC7937504447083E2ED6690256B770' }
    @{ Name = 'basswma'; Url = 'https://www.un4seen.com/files/basswma24.zip'; Sha256 = '75C37DD9DCE6DF9655E0F2B23D71196B32018E5F4339311B331145C63981C009' }
)

New-Item -ItemType Directory -Force -Path (Join-Path $dest 'x64') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $dest 'x86') | Out-Null

foreach ($package in $packages) {
    $zipPath = Join-Path $env:TEMP ($package.Name + '.zip')
    $extractDir = Join-Path $env:TEMP ($package.Name + '-extract')

    Write-Host ('正在下载 ' + $package.Name + ' ...')
    Invoke-WebRequest -Uri $package.Url -OutFile $zipPath -UseBasicParsing

    if (-not $SkipHashCheck) {
        $actual = (Get-FileHash $zipPath -Algorithm SHA256).Hash
        if ($actual -ne $package.Sha256) {
            throw ('SHA256 校验失败: ' + $package.Name + ' (期望 ' + $package.Sha256 + ', 实际 ' + $actual + ')' +
                '。如果确认是 un4seen 正常更新，请同步更新脚本里的哈希，或临时加 -SkipHashCheck。')
        }
    }

    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
    Expand-Archive $zipPath -DestinationPath $extractDir -Force

    # x64 供桌面构建；根目录的 dll 是 x86 备用；c\*.h 留作 FFI 绑定对照
    Copy-Item (Join-Path $extractDir 'x64\*.dll') (Join-Path $dest 'x64') -Force
    Copy-Item (Join-Path $extractDir '*.dll') (Join-Path $dest 'x86') -Force
    $headers = Join-Path $extractDir 'c'
    if (Test-Path $headers) {
        Copy-Item (Join-Path $headers '*.h') $dest -Force
    }

    Remove-Item $extractDir -Recurse -Force
    Remove-Item $zipPath -Force
}

Write-Host ('完成: ' + $dest + '\x64') -ForegroundColor Green
