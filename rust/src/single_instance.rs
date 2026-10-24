//! Windows 单实例：命名互斥体 + 唤起已有窗口。
//!
//! 双击两次会起两个进程，而 WASAPI 独占输出只允许一个进程持有设备——
//! 第二个必然静默回落到共享输出，用户看到的却是「声音变小了」。
//!
//! 「唤起」用命名事件通知第一个实例，而不是 `FindWindow` + `ShowWindow`：
//! 第二个进程在 `_setupWindow` 阶段就已经建好了自己的同名窗口，
//! `FindWindow` 会命中它自己那个隐藏窗口，跨进程 `ShowWindow` 等于白做。
//! 由第一个实例自己调 `windowManager.show()` 才是可靠路径（与托盘菜单同一套）。

use anyhow::{anyhow, Result};
use std::sync::OnceLock;
use windows::core::w;
use windows::Win32::Foundation::{GetLastError, ERROR_ALREADY_EXISTS, HANDLE, WAIT_OBJECT_0};
use windows::Win32::System::Threading::{
    CreateEventW, CreateMutexW, OpenEventW, SetEvent, WaitForSingleObject, EVENT_MODIFY_STATE,
};

/// 互斥体名：带上应用标记，避免和其它程序撞名
const MUTEX_NAME: windows::core::PCWSTR = w!("LampPlayer.SingleInstance");

/// 唤醒事件名：第二个实例 SetEvent，第一个实例轮询等待
const EVENT_NAME: windows::core::PCWSTR = w!("LampPlayer.Activate");

/// 句柄必须活到进程结束。`HANDLE` 在 windows 0.56 里是 `Copy` 且没有 `Drop`，
/// 存进 static 就不会再被关闭；互斥体一旦关闭，第二次启动又会被当成首个实例。
static MUTEX: OnceLock<usize> = OnceLock::new();
static EVENT: OnceLock<usize> = OnceLock::new();

fn event_handle() -> Option<HANDLE> {
    EVENT.get().map(|raw| HANDLE(*raw as isize))
}

/// 申请成为唯一实例；`false` 表示已有实例在运行。
pub fn acquire() -> Result<bool> {
    if MUTEX.get().is_some() {
        return Ok(true);
    }
    let handle = unsafe { CreateMutexW(None, false, MUTEX_NAME) }
        .map_err(|error| anyhow!("创建单实例互斥体失败: {error}"))?;
    // CreateMutexW 在已存在同名互斥体时仍返回有效句柄，用 LastError 区分
    let already = unsafe { GetLastError() } == ERROR_ALREADY_EXISTS;
    let _ = MUTEX.set(handle.0 as usize);

    // 自动重置事件：一次唤醒只对应一次 show，多余信号自动丢弃
    if let Ok(event) = unsafe { CreateEventW(None, false, false, EVENT_NAME) } {
        let _ = EVENT.set(event.0 as usize);
    }
    Ok(!already)
}

/// 通知已有实例把窗口亮出来；事件不存在（对端已退出）时返回 `false`。
pub fn signal_existing() -> Result<bool> {
    let event = match unsafe { OpenEventW(EVENT_MODIFY_STATE, false, EVENT_NAME) } {
        Ok(event) => event,
        Err(_) => return Ok(false),
    };
    Ok(unsafe { SetEvent(event) }.is_ok())
}

/// 首个实例侧：是否有另一个进程请求把窗口亮出来。
///
/// 非阻塞（超时 0 毫秒），Dart 侧每 500 ms 轮询一次。
pub fn take_activation() -> bool {
    let Some(event) = event_handle() else {
        return false;
    };
    unsafe { WaitForSingleObject(event, 0) == WAIT_OBJECT_0 }
}
