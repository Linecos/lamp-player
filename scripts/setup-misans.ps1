# 从小米官方下载 MiSans 字体，放进 assets/fonts/misans（构建时随安装包分发）
# 用法: .\scripts\setup-misans.ps1 [-Force] [-SkipHashCheck]
#
# 为什么不把字体文件提交进仓库：《MiSans 字体知识产权许可协议》禁止「单独再分发
# 字体文件」，所以字体只从官方下载到本机、跟着安装包走，不进版本库；同目录的
# MiSans-LICENSE.pdf 是协议要求「随字体副本保留」的许可协议，一并下载。
#
# 官方包是 227 MB 的全字重合集（10 个静态字重 + 1 个可变字体），这里只取歌词
# 用得上的常规一款（约 8 MB）。每多带一个字重安装包就多 8 MB，而粗细在下拉里
# 已能靠系统字体换。协议不允许改编字体，所以不做子集化；增减字重时同步改
# lib/src/common/text/bundled_fonts.dart 的 kMiSansFaces 与本表。

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$SkipHashCheck
)

$ErrorActionPreference = 'Stop'

$dest = Join-Path $PSScriptRoot '..\assets\fonts\misans'
$zipUrl = 'https://hyperos.mi.com/font-download/MiSans.zip'
# 小米更新字体包后这里会变；确认是官方更新就同步改哈希，或临时加 -SkipHashCheck
$zipSha256 = 'B6AA1FC827035922612DF8EDF36E5609BCA1C5441E25CD57572204569B7B81D9'
$licenseUrl = 'https://hyperos.mi.com/font-download/MiSans%E5%AD%97%E4%BD%93%E7%9F%A5%E8%AF%86%E4%BA%A7%E6%9D%83%E8%AE%B8%E5%8F%AF%E5%8D%8F%E8%AE%AE.pdf'
$licenseSha256 = '4A93A27CD2BD81B3B5ECFD0A853144A876FA26938A93A68443C67D74172FCB86'

# 条目名（zip 内路径）与落地文件名
$fonts = @(
    @{ Entry = 'MiSans/ttf/MiSans-Regular.ttf'; Name = 'MiSans-Regular.ttf' }
)

New-Item -ItemType Directory -Force -Path $dest | Out-Null

if (-not $Force) {
    $missing = @($fonts | Where-Object { -not (Test-Path (Join-Path $dest $_.Name)) })
    $hasLicense = Test-Path (Join-Path $dest 'MiSans-LICENSE.pdf')
    if ($missing.Count -eq 0 -and $hasLicense) {
        Write-Host 'MiSans 字体已就位，跳过下载（要强制重下用 -Force）。' -ForegroundColor Green
        exit 0
    }
    if ($missing.Count -gt 0) {
        Write-Host ('缺少: ' + (($missing | ForEach-Object { $_.Name }) -join ', ') + '，重新下载。') -ForegroundColor Yellow
    }
}

$zipPath = Join-Path $env:TEMP 'MiSans.zip'
Write-Host '正在下载 MiSans 字体包（约 227 MB，官方全字重合集）...'
Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing

if (-not $SkipHashCheck) {
    $actual = (Get-FileHash $zipPath -Algorithm SHA256).Hash
    if ($actual -ne $zipSha256) {
        throw ('SHA256 校验失败: MiSans.zip (期望 ' + $zipSha256 + ', 实际 ' + $actual + ')' +
            '。如果确认是小米官方更新，请同步更新脚本里的哈希，或临时加 -SkipHashCheck。')
    }
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    foreach ($font in $fonts) {
        $entry = $archive.Entries | Where-Object { $_.FullName -eq $font.Entry } | Select-Object -First 1
        if (-not $entry) {
            throw ('字体包里没有 ' + $font.Entry + '（小米改过目录结构？）')
        }
        $target = Join-Path $dest $font.Name
        # PowerShell 不支持调用 C# 扩展方法，写 $entry.ExtractToFile 会报「没有该方法」
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        Write-Host ('已解出 ' + $font.Name) -ForegroundColor Green
    }
} finally {
    $archive.Dispose()
    Remove-Item $zipPath -Force
}

# 协议要求：字体的任何副本都要带上许可协议
$licensePath = Join-Path $dest 'MiSans-LICENSE.pdf'
Write-Host '正在下载 MiSans 许可协议...'
Invoke-WebRequest -Uri $licenseUrl -OutFile $licensePath -UseBasicParsing
if (-not $SkipHashCheck) {
    $actual = (Get-FileHash $licensePath -Algorithm SHA256).Hash
    if ($actual -ne $licenseSha256) {
        throw ('SHA256 校验失败: MiSans-LICENSE.pdf (期望 ' + $licenseSha256 + ', 实际 ' + $actual + ')')
    }
}

$total = (Get-ChildItem $dest -Filter '*.ttf' | Measure-Object -Property Length -Sum).Sum / 1MB
Write-Host ('完成: ' + $dest + ('（字体共 ' + [math]::Round($total, 1) + ' MB）')) -ForegroundColor Green
Write-Host '提示：应用内使用 MiSans 时须注明字体来源，本仓库已在设置页与关于弹窗标注。'
