# 打 Windows 发行包：便携 zip + Inno Setup 安装包
# 用法: .\scripts\package.ps1 [-Version 0.1.0] [-SkipBuild] [-NoInstaller] [-NoZip]
#
# 产物都在 dist\ 下（已 gitignore）：
#   LampPlayer-<版本>\         便携目录（直接运行 lamp_player.exe）
#   LampPlayer-<版本>.zip      便携包，解压即用
#   LampPlayer-<版本>-setup.exe 安装包，需要本机装了 Inno Setup 6.3+
#
# 只跑 build + zip 不需要装任何额外工具；安装包那一步找不到 ISCC 会明确提示，
# 不会静默跳过。

[CmdletBinding()]
param(
    # 不传就从 pubspec.yaml 的 version 读（去掉 +1 的构建号）
    [string]$Version,
    [switch]$SkipBuild,
    [switch]$NoInstaller,
    [switch]$NoZip
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$release = Join-Path $root 'build\windows\x64\runner\Release'
$dist = Join-Path $root 'dist'

if (-not $Version) {
    $match = Select-String -Path (Join-Path $root 'pubspec.yaml') -Pattern '^version:\s*(\S+)' |
        Select-Object -First 1
    if (-not $match) {
        throw 'pubspec.yaml 里找不到 version'
    }
    $Version = ($match.Matches[0].Groups[1].Value -split '\+')[0]
}

Write-Host "==> Lamp Player $Version" -ForegroundColor Cyan

if (-not $SkipBuild) {
    Write-Host '==> flutter build windows --release' -ForegroundColor Cyan
    Push-Location $root
    try {
        & flutter build windows --release
        if ($LASTEXITCODE -ne 0) {
            throw "flutter build 失败（exit $LASTEXITCODE）"
        }
    }
    finally {
        Pop-Location
    }
}

# 缺一样都跑不起来：exe + 两个原生库 + data 目录（icudtl / app.so / assets）
foreach ($required in @(
        'lamp_player.exe',
        'rust_lib_lamp_player.dll',
        'flutter_windows.dll',
        'data'
    )) {
    if (-not (Test-Path (Join-Path $release $required))) {
        throw "Release 目录里缺 $required：先去掉 -SkipBuild 跑一次完整构建"
    }
}
$bassCount = (Get-ChildItem $release -Filter 'bass*.dll' -ErrorAction SilentlyContinue).Count
if ($bassCount -eq 0) {
    Write-Warning 'Release 里没有 bass*.dll：先跑 scripts\setup-bass.ps1，否则打出来的包放不出声'
}

New-Item -ItemType Directory -Force -Path $dist | Out-Null

# ---- 便携目录 ----
$stage = Join-Path $dist "LampPlayer-$Version"
if (Test-Path $stage) {
    Remove-Item $stage -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Copy-Item (Join-Path $release '*') -Destination $stage -Recurse -Force
Write-Host "==> 便携目录: $stage" -ForegroundColor Green

if (-not $NoZip) {
    $zip = Join-Path $dist "LampPlayer-$Version.zip"
    if (Test-Path $zip) {
        Remove-Item $zip -Force
    }
    # 传目录本身，压出来里面就是 LampPlayer-<版本>\...，解压得到一层文件夹
    Compress-Archive -Path $stage -DestinationPath $zip -CompressionLevel Optimal
    $mb = [math]::Round((Get-Item $zip).Length / 1MB, 1)
    Write-Host "==> 便携包: $zip ($mb MB)" -ForegroundColor Green
}

# ---- 安装包 ----
if (-not $NoInstaller) {
    $iscc = $null
    foreach ($candidate in @(
            (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
            (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe')
        )) {
        if (Test-Path $candidate) {
            $iscc = $candidate
            break
        }
    }
    if (-not $iscc) {
        $command = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
        if ($command) {
            $iscc = $command.Source
        }
    }

    if (-not $iscc) {
        Write-Warning '没找到 ISCC.exe，安装包这一步跳过。'
        Write-Host '  装 Inno Setup 6.3+（https://jrsoftware.org/isdl.php），然后用 winget：' -ForegroundColor Yellow
        Write-Host '    winget install --id JRSoftware.InnoSetup' -ForegroundColor Yellow
        Write-Host '  装完重跑本脚本即可；或手动执行：' -ForegroundColor Yellow
        Write-Host "    ISCC.exe installer\lamp_player.iss /DMyAppVersion=$Version" -ForegroundColor Yellow
    }
    else {
        $iss = Join-Path $root 'installer\lamp_player.iss'
        # 资源里的「文件版本」要四段纯数字，AppVersion 是给人看的
        $quad = (@($Version -split '\.') + @('0', '0', '0', '0'))[0..3] -join '.'
        Write-Host '==> Inno Setup 编译安装包' -ForegroundColor Cyan
        & $iscc "/DMyAppVersion=$Version" "/DMyAppVersionQuad=$quad" $iss
        if ($LASTEXITCODE -ne 0) {
            throw "ISCC 编译失败（exit $LASTEXITCODE）"
        }
        $setup = Join-Path $dist "LampPlayer-$Version-setup.exe"
        if (Test-Path $setup) {
            $mb = [math]::Round((Get-Item $setup).Length / 1MB, 1)
            Write-Host "==> 安装包: $setup ($mb MB)" -ForegroundColor Green
        }
    }
}

Write-Host '==> 完成' -ForegroundColor Cyan
