# 从 un4seen.com 官网下载 BASS 2.4 Windows SDK 并放到 third_party 目录
# 用法: .\scripts\setup-bass.ps1

$ErrorActionPreference = 'Stop'

$dest = Join-Path $PSScriptRoot '..\third_party\bass\windows'
$zipPath = Join-Path $env:TEMP 'bass24.zip'

if (Test-Path (Join-Path $dest 'x64\bass.dll')) {
    Write-Host 'BASS 已存在，跳过下载。' -ForegroundColor Green
    exit 0
}

Write-Host '正在从 un4seen.com 下载 BASS 2.4 ...'
Invoke-WebRequest -Uri 'https://www.un4seen.com/files/bass24.zip' -OutFile $zipPath -UseBasicParsing

$extractDir = Join-Path $env:TEMP 'bass24-extract'
if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
Expand-Archive $zipPath -DestinationPath $extractDir -Force

# x64 用于 Windows 桌面构建
New-Item -ItemType Directory -Force -Path (Join-Path $dest 'x64') | Out-Null
Copy-Item (Join-Path $extractDir 'x64\bass.dll') (Join-Path $dest 'x64\bass.dll') -Force
# 头文件留作参考（Rust FFI 绑定对照）
Copy-Item (Join-Path $extractDir 'c\bass.h') (Join-Path $dest 'bass.h') -Force
# x86 备用
New-Item -ItemType Directory -Force -Path (Join-Path $dest 'x86') | Out-Null
Copy-Item (Join-Path $extractDir 'bass.dll') (Join-Path $dest 'x86\bass.dll') -Force

Write-Host "完成: $dest\x64\bass.dll" -ForegroundColor Green
