<#
.SYNOPSIS
  给「未响应」的 Lamp Player 抓一份线程栈转储。

.DESCRIPTION
  这类故障（界面卡住、音乐还在放、过一会进程没了）事后什么都查不到：事件日志
  没有崩溃记录，%LOCALAPPDATA%\CrashDumps 里也没有 dmp。最直接的办法是**在卡住的
  那一刻**把进程转储下来——所有线程的调用栈都在里面，UI 线程卡在哪一行一目了然。

  用法（默认只在窗口真的「未响应」时才抓）：
    pwsh -File scripts\dump-hang.ps1
    pwsh -File scripts\dump-hang.ps1 -Force     # 不管响应与否，直接抓一份做对照

  产物在 %TEMP%\lamp_player_<pid>_<时间>.dmp，用 Visual Studio / WinDbg 打开后
  执行 `~*k` 看全部线程栈，`!analyze -hang` 分析死锁。

  注意：MiniDumpNormal 级别的转储很小（几 MB），足够看调用栈，但不含全部内存。
#>
param(
  [switch]$Force,
  [string]$ProcessName = 'lamp_player.exe'
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class MiniDump {
    [DllImport("dbghelp.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool MiniDumpWriteDump(
        IntPtr hProcess, int processId, IntPtr hFile,
        int dumpType, IntPtr exceptionParam, IntPtr userStreamParam, IntPtr callbackParam);
}
'@

# MiniDumpNormal = 0x0，MiniDumpWithThreadInfo = 0x1000：要栈就够，不写全内存
$dumpType = 0x1000

$targets = @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($ProcessName)) -ErrorAction SilentlyContinue)
if ($targets.Count -eq 0) {
  Write-Output "没有找到运行中的 $ProcessName"
  exit 1
}

foreach ($proc in $targets) {
  $responding = $true
  try { $responding = $proc.Responding } catch { $responding = $true }
  if (-not $responding -or $Force) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $path = Join-Path $env:TEMP "lamp_player_$($proc.Id)_$stamp.dmp"
    $handle = [Diagnostics.Process]::GetProcessById($proc.Id).Handle
    $file = [IO.File]::Create($path)
    try {
      $ok = [MiniDump]::MiniDumpWriteDump(
        $handle, $proc.Id, $file.SafeFileHandle.DangerousGetHandle(),
        $dumpType, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
    } finally {
      $file.Dispose()
    }
    if ($ok) {
      $size = [Math]::Round((Get-Item -LiteralPath $path).Length / 1MB, 1)
      Write-Output "已转储：$path（$size MB，Responding=$responding）"
    } else {
      Write-Output "转储失败：Win32 错误 $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
  } else {
    Write-Output "pid $($proc.Id) 仍在响应，未转储（加 -Force 可强制转储）"
  }
}
