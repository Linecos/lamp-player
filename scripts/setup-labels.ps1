#requires -Version 5.1
<#
.SYNOPSIS
    初始化仓库的 issue / PR 标签。

.DESCRIPTION
    需要已登录的 GitHub CLI（gh auth login）且对仓库有写权限。
    幂等：同名标签会更新颜色与描述，不会重复创建。
    只在仓库建立初期跑一次；之后新增标签直接改脚本再跑。

.EXAMPLE
    .\scripts\setup-labels.ps1

.EXAMPLE
    .\scripts\setup-labels.ps1 -Repo Linecos/lamp-player
#>
[CmdletBinding()]
param(
    [string]$Repo = 'Linecos/lamp-player'
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'gh 不在 PATH 里。装 GitHub CLI 并 gh auth login 后再跑。'
}

$labels = @(
    @{ Name = 'bug'; Color = 'd73a4a'; Desc = '可复现的缺陷' }
    @{ Name = 'enhancement'; Color = 'a2eeef'; Desc = '新功能或体验改进' }
    @{ Name = 'documentation'; Color = '0075ca'; Desc = '文档、注释、示例' }
    @{ Name = 'good first issue'; Color = '7057ff'; Desc = '适合第一次参与，范围小、依赖少' }
    @{ Name = 'help wanted'; Color = '008672'; Desc = '欢迎认领，owner 不急着做' }
    @{ Name = 'question'; Color = 'd876e4'; Desc = '用法或设计上的疑问' }
    @{ Name = 'rust'; Color = 'dea584'; Desc = 'Rust 侧改动' }
    @{ Name = 'flutter'; Color = '02569b'; Desc = 'Dart / Flutter 侧改动' }
    @{ Name = 'ci'; Color = 'ededed'; Desc = '构建、工作流、脚本' }
    @{ Name = 'performance'; Color = 'fbca04'; Desc = '性能相关（大曲库、渲染、扫描）' }
    @{ Name = 'api-contract'; Color = 'c5def5'; Desc = '涉及 Rust↔Dart 接口契约的改动' }
)

Write-Host ('目标仓库：' + $Repo) -ForegroundColor Cyan

foreach ($label in $labels) {
    Write-Host ('  -> ' + $label.Name)
    gh label create $label.Name --repo $Repo --color $label.Color --description $label.Desc --force
    if ($LASTEXITCODE -ne 0) {
        Write-Host ('     失败：' + $label.Name) -ForegroundColor Red
    }
}

Write-Host ''
Write-Host '完成。可在仓库 Issues -> Labels 里调整。' -ForegroundColor Green
