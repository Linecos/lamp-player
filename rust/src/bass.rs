//! BASS 音频引擎的运行时加载与播放控制。
//!
//! 内部模块，只被 [`crate::api::player`] 调用，不导出给 Dart。
//!
//! - 所有 BASS 调用都在同一条引擎线程上串行执行（命令队列 + 回执通道）
//! - [`is_available`] / [`state`] 只读原子量，可在 UI 的 `build` 里直接调用
//! - 非 Windows 平台编译为空实现，保证 CI 的 Linux job 能通过

use anyhow::Result;

/// 播放状态（与 `api::player::PlaybackState` 一一对应）
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Stopped,
    Playing,
    Paused,
}

/// BASS 是否可用（DLL 加载 + 初始化成功）
///
/// 首次调用会触发初始化并等待引擎就绪（约几十毫秒），之后只读原子量。
pub fn is_available() -> bool {
    imp::available()
}

/// 当前播放状态
pub fn state() -> State {
    imp::state()
}

/// 加载并播放指定文件，会先停止当前曲目
pub fn play(path: &str) -> Result<()> {
    imp::play(path)
}

/// 暂停
pub fn pause() -> Result<()> {
    imp::pause()
}

/// 从暂停处继续
pub fn resume() -> Result<()> {
    imp::resume()
}

/// 停止并释放当前曲目
pub fn stop() -> Result<()> {
    imp::stop()
}

/// 跳转到指定位置（秒）
pub fn seek(position_secs: f64) -> Result<()> {
    imp::seek(position_secs)
}

/// 设置音量（0.0~1.0，越界截断）
pub fn set_volume(volume: f64) -> Result<()> {
    imp::set_volume(volume)
}

/// 当前位置（秒），未加载曲目时为 0.0
pub fn position() -> Result<f64> {
    imp::position()
}

/// 总时长（秒），未加载曲目时为 0.0
pub fn duration() -> Result<f64> {
    imp::duration()
}

#[cfg(windows)]
mod imp {
    use super::State;
    use anyhow::{anyhow, bail, Result};
    use libloading::Library;
    use std::ffi::c_void;
    use std::os::windows::ffi::OsStrExt;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
    use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
    use std::sync::OnceLock;
    use std::thread;

    const ST_STOPPED: u8 = 0;
    const ST_PLAYING: u8 = 1;
    const ST_PAUSED: u8 = 2;

    /// 状态轮询间隔，用于发现曲目自然播完
    const TICK: std::time::Duration = std::time::Duration::from_millis(200);

    static AVAILABLE: AtomicBool = AtomicBool::new(false);
    static STATE: AtomicU8 = AtomicU8::new(ST_STOPPED);

    fn store_state(state: State) {
        let raw = match state {
            State::Stopped => ST_STOPPED,
            State::Playing => ST_PLAYING,
            State::Paused => ST_PAUSED,
        };
        STATE.store(raw, Ordering::SeqCst);
    }

    pub fn state() -> State {
        match STATE.load(Ordering::SeqCst) {
            ST_PLAYING => State::Playing,
            ST_PAUSED => State::Paused,
            _ => State::Stopped,
        }
    }

    const BASS_UNICODE: u32 = 0x8000_0000;
    const BASS_STREAM_PRESCAN: u32 = 0x0002_0000;
    const BASS_ATTRIB_VOL: u32 = 2;
    const BASS_POS_BYTE: u32 = 0;

    const ACTIVE_PLAYING: u32 = 1;
    const ACTIVE_STALLED: u32 = 2;
    const ACTIVE_PAUSED: u32 = 3;
    const ACTIVE_PAUSED_DEVICE: u32 = 4;

    /// 支持的插件，缺失会被跳过而不是整体失败
    const PLUGINS: [&str; 5] = [
        "bassflac.dll",
        "bassopus.dll",
        "bass_aac.dll",
        "bassape.dll",
        "basswma.dll",
    ];

    type Reply<T> = Sender<Result<T>>;

    enum Cmd {
        Play(String, Reply<()>),
        Pause(Reply<()>),
        Resume(Reply<()>),
        Stop(Reply<()>),
        Seek(f64, Reply<()>),
        Volume(f32, Reply<()>),
        Position(Reply<f64>),
        Duration(Reply<f64>),
    }

    struct Api {
        _lib: Library,
        init: unsafe extern "system" fn(i32, u32, u32, *mut c_void, *const c_void) -> i32,
        free: unsafe extern "system" fn() -> i32,
        plugin_load: unsafe extern "system" fn(*const u16, u32) -> u32,
        stream_create_file: unsafe extern "system" fn(u32, *const c_void, u64, u64, u32) -> u32,
        stream_free: unsafe extern "system" fn(u32) -> i32,
        channel_play: unsafe extern "system" fn(u32, i32) -> i32,
        channel_pause: unsafe extern "system" fn(u32) -> i32,
        channel_stop: unsafe extern "system" fn(u32) -> i32,
        channel_is_active: unsafe extern "system" fn(u32) -> u32,
        channel_set_position: unsafe extern "system" fn(u32, u64, u32) -> i32,
        channel_get_position: unsafe extern "system" fn(u32, u32) -> u64,
        channel_get_length: unsafe extern "system" fn(u32, u32) -> u64,
        channel_set_attribute: unsafe extern "system" fn(u32, u32, f32) -> i32,
        channel_bytes2seconds: unsafe extern "system" fn(u32, u64) -> f64,
        channel_seconds2bytes: unsafe extern "system" fn(u32, f64) -> u64,
        error_get_code: unsafe extern "system" fn() -> i32,
    }

    impl Api {
        unsafe fn load(dir: &Path) -> Result<Self> {
            let lib = Library::new(dir.join("bass.dll"))
                .map_err(|e| anyhow!("加载 bass.dll 失败: {e}"))?;
            Ok(Self {
                init: sym(&lib, "BASS_Init")?,
                free: sym(&lib, "BASS_Free")?,
                plugin_load: sym(&lib, "BASS_PluginLoad")?,
                stream_create_file: sym(&lib, "BASS_StreamCreateFile")?,
                stream_free: sym(&lib, "BASS_StreamFree")?,
                channel_play: sym(&lib, "BASS_ChannelPlay")?,
                channel_pause: sym(&lib, "BASS_ChannelPause")?,
                channel_stop: sym(&lib, "BASS_ChannelStop")?,
                channel_is_active: sym(&lib, "BASS_ChannelIsActive")?,
                channel_set_position: sym(&lib, "BASS_ChannelSetPosition")?,
                channel_get_position: sym(&lib, "BASS_ChannelGetPosition")?,
                channel_get_length: sym(&lib, "BASS_ChannelGetLength")?,
                channel_set_attribute: sym(&lib, "BASS_ChannelSetAttribute")?,
                channel_bytes2seconds: sym(&lib, "BASS_ChannelBytes2Seconds")?,
                channel_seconds2bytes: sym(&lib, "BASS_ChannelSeconds2Bytes")?,
                error_get_code: sym(&lib, "BASS_ErrorGetCode")?,
                _lib: lib,
            })
        }
    }

    unsafe fn sym<T: Copy>(lib: &Library, name: &str) -> Result<T> {
        let mut raw = Vec::with_capacity(name.len() + 1);
        raw.extend_from_slice(name.as_bytes());
        raw.push(0);
        let symbol = lib
            .get::<T>(&*raw)
            .map_err(|e| anyhow!("bass.dll 缺少符号 {name}: {e}"))?;
        Ok(*symbol)
    }

    struct Engine {
        api: Api,
        stream: u32,
        volume: f32,
    }

    impl Engine {
        fn new() -> Result<Self> {
            let dir = dll_dir().ok_or_else(|| {
                anyhow!("未找到 bass.dll（应在 exe 同级目录或 third_party/bass/windows/x64）")
            })?;
            let api = unsafe { Api::load(&dir)? };

            // -1 = 系统默认设备；0 = 无输出（CI/无声卡环境用 LAMP_BASS_DEVICE=0）
            let device = std::env::var("LAMP_BASS_DEVICE")
                .ok()
                .and_then(|v| v.parse::<i32>().ok())
                .unwrap_or(-1);
            let ok =
                unsafe { (api.init)(device, 44100, 0, std::ptr::null_mut(), std::ptr::null()) };
            if ok == 0 {
                bail!("BASS_Init 失败: {}", last_error(&api));
            }

            for name in PLUGINS {
                let path = dir.join(name);
                if !path.is_file() {
                    continue;
                }
                let wide = wide(&path);
                // 单个插件失败不影响整体，只是少了对应格式
                unsafe { (api.plugin_load)(wide.as_ptr(), BASS_UNICODE) };
            }

            Ok(Self {
                api,
                stream: 0,
                volume: 1.0,
            })
        }

        fn play(&mut self, path: &str) -> Result<()> {
            if path.is_empty() {
                bail!("音频路径为空");
            }
            self.release();

            let wide = wide(Path::new(path));
            let flags = BASS_UNICODE | BASS_STREAM_PRESCAN;
            let handle = unsafe {
                (self.api.stream_create_file)(0, wide.as_ptr() as *const c_void, 0, 0, flags)
            };
            if handle == 0 {
                return Err(anyhow!("无法打开音频文件: {}", last_error(&self.api)));
            }
            self.stream = handle;

            // 音量是 per-channel 属性，换曲后必须重新应用
            unsafe { (self.api.channel_set_attribute)(handle, BASS_ATTRIB_VOL, self.volume) };

            if unsafe { (self.api.channel_play)(handle, 1) } == 0 {
                let err = last_error(&self.api);
                self.release();
                return Err(anyhow!("播放失败: {err}"));
            }
            store_state(State::Playing);
            Ok(())
        }

        fn pause(&mut self) -> Result<()> {
            self.ensure_stream()?;
            if unsafe { (self.api.channel_pause)(self.stream) } == 0 {
                return Err(anyhow!("暂停失败: {}", last_error(&self.api)));
            }
            store_state(State::Paused);
            Ok(())
        }

        fn resume(&mut self) -> Result<()> {
            self.ensure_stream()?;
            if unsafe { (self.api.channel_play)(self.stream, 0) } == 0 {
                return Err(anyhow!("继续播放失败: {}", last_error(&self.api)));
            }
            store_state(State::Playing);
            Ok(())
        }

        fn stop(&mut self) -> Result<()> {
            self.release();
            Ok(())
        }

        fn seek(&mut self, secs: f64) -> Result<()> {
            self.ensure_stream()?;
            if !secs.is_finite() || secs < 0.0 {
                bail!("跳转位置非法: {secs}");
            }
            let total = self.duration()?;
            if total > 0.0 && secs > total {
                bail!("跳转位置超出曲目时长: {secs} > {total}");
            }
            let bytes = unsafe { (self.api.channel_seconds2bytes)(self.stream, secs) };
            if unsafe { (self.api.channel_set_position)(self.stream, bytes, BASS_POS_BYTE) } == 0 {
                return Err(anyhow!("跳转失败: {}", last_error(&self.api)));
            }
            Ok(())
        }

        fn set_volume(&mut self, volume: f32) -> Result<()> {
            self.volume = volume.clamp(0.0, 1.0);
            if self.stream != 0 {
                unsafe {
                    (self.api.channel_set_attribute)(self.stream, BASS_ATTRIB_VOL, self.volume)
                };
            }
            Ok(())
        }

        fn position(&self) -> Result<f64> {
            if self.stream == 0 {
                return Ok(0.0);
            }
            let bytes = unsafe { (self.api.channel_get_position)(self.stream, BASS_POS_BYTE) };
            Ok(unsafe { (self.api.channel_bytes2seconds)(self.stream, bytes) })
        }

        fn duration(&self) -> Result<f64> {
            if self.stream == 0 {
                return Ok(0.0);
            }
            let bytes = unsafe { (self.api.channel_get_length)(self.stream, BASS_POS_BYTE) };
            Ok(unsafe { (self.api.channel_bytes2seconds)(self.stream, bytes) })
        }

        /// 曲目自然播完后把状态刷回 Stopped
        fn refresh(&self) {
            if self.stream == 0 {
                store_state(State::Stopped);
                return;
            }
            let active = unsafe { (self.api.channel_is_active)(self.stream) };
            let state = match active {
                ACTIVE_PLAYING | ACTIVE_STALLED => State::Playing,
                ACTIVE_PAUSED | ACTIVE_PAUSED_DEVICE => State::Paused,
                _ => State::Stopped,
            };
            store_state(state);
        }

        fn ensure_stream(&self) -> Result<()> {
            if self.stream == 0 {
                bail!("当前没有加载曲目");
            }
            Ok(())
        }

        fn release(&mut self) {
            if self.stream != 0 {
                unsafe {
                    (self.api.channel_stop)(self.stream);
                    (self.api.stream_free)(self.stream);
                }
                self.stream = 0;
            }
            store_state(State::Stopped);
        }

        fn shutdown(&mut self) {
            self.release();
            unsafe { (self.api.free)() };
        }
    }

    fn last_error(api: &Api) -> String {
        let code = unsafe { (api.error_get_code)() };
        format!("BASS 错误 {code}（{}）", error_text(code))
    }

    fn error_text(code: i32) -> &'static str {
        match code {
            1 => "内存不足",
            2 => "无法打开文件",
            3 => "找不到可用的音频设备",
            5 => "无效的句柄",
            6 => "不支持的采样格式",
            7 => "无效的位置",
            8 => "BASS_Init 尚未成功调用",
            17 => "文件不含音频数据",
            20 => "参数非法",
            23 => "设备编号非法",
            31 => "文件没有采样数据",
            37 => "请求的操作不可用",
            41 => "不支持的文件格式",
            44 => "缺少对应的解码器",
            _ => "未知错误",
        }
    }

    fn dll_dir() -> Option<PathBuf> {
        let mut candidates = Vec::new();
        if let Ok(exe) = std::env::current_exe() {
            if let Some(parent) = exe.parent() {
                candidates.push(parent.to_path_buf());
            }
        }
        // 开发/测试期：构建产物目录里没有 DLL 时回落到仓库内的 third_party
        candidates.push(
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../third_party/bass/windows/x64"),
        );
        candidates
            .into_iter()
            .find(|dir| dir.join("bass.dll").is_file())
    }

    fn wide(path: &Path) -> Vec<u16> {
        path.as_os_str().encode_wide().chain(Some(0)).collect()
    }

    struct Shared {
        tx: Sender<Cmd>,
    }

    static ENGINE: OnceLock<Result<Shared, String>> = OnceLock::new();

    fn shared() -> Result<&'static Shared> {
        match ENGINE.get_or_init(|| spawn().map_err(|e| e.to_string())) {
            Ok(shared) => Ok(shared),
            Err(err) => Err(anyhow!("播放引擎不可用: {err}")),
        }
    }

    fn spawn() -> Result<Shared> {
        let (tx, rx) = channel::<Cmd>();
        let (ready_tx, ready_rx) = channel::<Result<(), String>>();

        thread::Builder::new()
            .name("bass-engine".to_string())
            .spawn(move || match Engine::new() {
                Ok(engine) => {
                    AVAILABLE.store(true, Ordering::SeqCst);
                    let _ = ready_tx.send(Ok(()));
                    run(engine, rx);
                }
                Err(err) => {
                    let _ = ready_tx.send(Err(err.to_string()));
                }
            })
            .map_err(|e| anyhow!("创建播放线程失败: {e}"))?;

        match ready_rx.recv_timeout(std::time::Duration::from_secs(5)) {
            Ok(Ok(())) => Ok(Shared { tx }),
            Ok(Err(err)) => bail!("{err}"),
            Err(_) => bail!("播放引擎初始化超时"),
        }
    }

    fn run(mut engine: Engine, rx: Receiver<Cmd>) {
        loop {
            match rx.recv_timeout(TICK) {
                Ok(Cmd::Play(path, reply)) => {
                    let _ = reply.send(engine.play(&path));
                }
                Ok(Cmd::Pause(reply)) => {
                    let _ = reply.send(engine.pause());
                }
                Ok(Cmd::Resume(reply)) => {
                    let _ = reply.send(engine.resume());
                }
                Ok(Cmd::Stop(reply)) => {
                    let _ = reply.send(engine.stop());
                }
                Ok(Cmd::Seek(secs, reply)) => {
                    let _ = reply.send(engine.seek(secs));
                }
                Ok(Cmd::Volume(volume, reply)) => {
                    let _ = reply.send(engine.set_volume(volume));
                }
                Ok(Cmd::Position(reply)) => {
                    let _ = reply.send(engine.position());
                }
                Ok(Cmd::Duration(reply)) => {
                    let _ = reply.send(engine.duration());
                }
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => {
                    engine.shutdown();
                    return;
                }
            }
            engine.refresh();
        }
    }

    fn call<T>(make: impl FnOnce(Reply<T>) -> Cmd) -> Result<T> {
        let shared = shared()?;
        let (tx, rx) = channel();
        shared
            .tx
            .send(make(tx))
            .map_err(|_| anyhow!("播放引擎已退出"))?;
        rx.recv().map_err(|_| anyhow!("播放引擎无响应"))?
    }

    pub fn available() -> bool {
        if AVAILABLE.load(Ordering::SeqCst) {
            return true;
        }
        shared().is_ok()
    }

    pub fn play(path: &str) -> Result<()> {
        call(|reply| Cmd::Play(path.to_string(), reply))
    }

    pub fn pause() -> Result<()> {
        call(Cmd::Pause)
    }

    pub fn resume() -> Result<()> {
        call(Cmd::Resume)
    }

    pub fn stop() -> Result<()> {
        call(Cmd::Stop)
    }

    pub fn seek(position_secs: f64) -> Result<()> {
        call(|reply| Cmd::Seek(position_secs, reply))
    }

    pub fn set_volume(volume: f64) -> Result<()> {
        call(|reply| Cmd::Volume(volume as f32, reply))
    }

    pub fn position() -> Result<f64> {
        call(Cmd::Position)
    }

    pub fn duration() -> Result<f64> {
        call(Cmd::Duration)
    }
}

#[cfg(not(windows))]
mod imp {
    use super::State;
    use anyhow::{bail, Result};

    pub fn available() -> bool {
        false
    }

    pub fn state() -> State {
        State::Stopped
    }

    fn unsupported<T>() -> Result<T> {
        bail!("BASS 播放引擎仅支持 Windows")
    }

    pub fn play(_path: &str) -> Result<()> {
        unsupported()
    }

    pub fn pause() -> Result<()> {
        unsupported()
    }

    pub fn resume() -> Result<()> {
        unsupported()
    }

    pub fn stop() -> Result<()> {
        unsupported()
    }

    pub fn seek(_position_secs: f64) -> Result<()> {
        unsupported()
    }

    pub fn set_volume(_volume: f64) -> Result<()> {
        unsupported()
    }

    pub fn position() -> Result<f64> {
        unsupported()
    }

    pub fn duration() -> Result<f64> {
        unsupported()
    }
}
