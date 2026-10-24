//! Windows 实现：BASS 符号表、命令队列与共享 / 独占两条输出路径。
//!
//! 由 `bass.rs` 以 `#[path]` 声明为 `imp`，对外只通过父模块的公开函数访问。
//! 所有 BASS 调用都在同一条引擎线程上串行执行（命令队列 + 回执通道）。

use super::wasapi;
use super::State;
use anyhow::{anyhow, bail, Result};
use std::ffi::c_void;
use std::path::{Path, PathBuf};

use super::api::{dll_dir, last_error, wide, Api};
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;

const ST_STOPPED: u8 = 0;
const ST_PLAYING: u8 = 1;
const ST_PAUSED: u8 = 2;

/// 状态轮询间隔，用于发现曲目自然播完
const TICK: std::time::Duration = std::time::Duration::from_millis(200);

static AVAILABLE: AtomicBool = AtomicBool::new(false);
static STATE: AtomicU8 = AtomicU8::new(ST_STOPPED);

/// 实际生效的输出是否为 WASAPI 独占（供 UI 同步读取）
static EXCLUSIVE: AtomicBool = AtomicBool::new(false);

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
const BASS_STREAM_DECODE: u32 = 0x0020_0000;
const BASS_SAMPLE_FLOAT: u32 = 0x0000_0100;
const BASS_ATTRIB_VOL: u32 = 2;
const BASS_ATTRIB_SRC: u32 = 8;
const BASS_POS_BYTE: u32 = 0;
const BASS_ERROR_BUSY: i32 = 46;

/// BASS 内置的 DX8 参数均衡器（不需要 bass_fx 插件）
const BASS_FX_DX8_PARAMEQ: u32 = 7;

/// 10 段均衡器的中心频率（Hz）
const EQ_CENTERS: [f32; 10] = [
    31.0, 62.0, 125.0, 250.0, 500.0, 1_000.0, 2_000.0, 4_000.0, 8_000.0, 16_000.0,
];

/// 每段带宽（倍频程）：1.0 约等于 Q=1.41，相邻频段刚好衔接
const EQ_BANDWIDTH: f32 = 1.0;

/// 增益上下限（dB）：超过 ±15 dB 只会让失真变明显
const EQ_MAX_GAIN: f32 = 15.0;

/// `BASS_DX8_PARAMEQ` 的内存布局（与 bass.h 一致）
#[repr(C)]
#[derive(Clone, Copy)]
struct Dx8ParamEq {
    f_center: f32,
    f_bandwidth: f32,
    f_gain: f32,
}

/// 独占模式的设备缓冲（秒）。100 ms 足够稳，延迟对音乐播放无感。
const WASAPI_BUFFER_SECS: f32 = 0.1;

/// 独占模式下“没有在播”多久后把设备交还系统。
///
/// 播完队列停在末态时如果一直占着设备，浏览器等程序会直接没声音；
/// 但暂停不能算（用户随时会继续），所以只对 Stopped 计时。
const EXCLUSIVE_IDLE: std::time::Duration = std::time::Duration::from_secs(3);

/// 空闲阈值：测试可以用 `LAMP_EXCLUSIVE_IDLE_SECS` 调短
fn idle_timeout() -> std::time::Duration {
    static IDLE: OnceLock<std::time::Duration> = OnceLock::new();
    *IDLE.get_or_init(|| {
        std::env::var("LAMP_EXCLUSIVE_IDLE_SECS")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
            .map(std::time::Duration::from_secs)
            .unwrap_or(EXCLUSIVE_IDLE)
    })
}

/// 采样率转换质量：4 = 64 点 sinc 插值（BASS 默认 2 = 16 点）。
///
/// 输出设备在 Windows Vista+ 上按设备原生采样率工作，44.1 kHz 素材在
/// 48 kHz 设备上必定要重采样，这里用最高档减少混叠。
const SRC_QUALITY: f32 = 4.0;

/// 打开音频流用的标志。`float_samples` 决定是否要 32 位浮点样本。
fn stream_flags(float_samples: bool) -> u32 {
    let mut flags = BASS_UNICODE | BASS_STREAM_PRESCAN;
    if float_samples {
        flags |= BASS_SAMPLE_FLOAT;
    }
    flags
}

/// 独占模式下的解码流标志：不直接出声，交给 WASAPI 回调去拉
fn decode_flags() -> u32 {
    BASS_UNICODE | BASS_STREAM_PRESCAN | BASS_SAMPLE_FLOAT | BASS_STREAM_DECODE
}

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
    SetEq(bool, Vec<f32>, Reply<()>),
    SetExclusive(bool, Reply<()>),
    OutputInfo(Reply<String>),
    Shutdown(Reply<()>),
}

struct Slot {
    /// 解码源流：只用于 position / seek 与拆除，**不作为输出源**
    stream: u32,
    /// 混音流：独占模式下真正被设备回调拉取的就是它
    ///
    /// 源流已挂到混音器上，直接拉源流会绕过混音器的重采样与音量
    /// （44.1k 素材在 48k 设备上变成 1.088 倍速，音量滑块也会失效）。
    mixer: u32,
    paused: bool,
    get_data: unsafe extern "system" fn(u32, *mut c_void, u32) -> u32,
}

/// WASAPI 回调：往设备缓冲里填数据。
///
/// 暂停或没有曲目时写静音而不是返回 0 —— 返回 0 会被当成“输出结束”，
/// 设备一停一启就会在恢复时爆一下。
unsafe extern "system" fn wasapi_proc(buffer: *mut c_void, length: u32, user: *mut c_void) -> u32 {
    if buffer.is_null() || length == 0 || user.is_null() {
        return 0;
    }
    let slot = &*(user as *const Mutex<Slot>);
    let Ok(guard) = slot.lock() else {
        return 0;
    };
    // 独占输出必须以混音流为数据源：源流没有经过重采样与音量处理
    let source = if guard.mixer != 0 {
        guard.mixer
    } else {
        guard.stream
    };
    if guard.paused || source == 0 {
        std::ptr::write_bytes(buffer as *mut u8, 0, length as usize);
        return length;
    }
    let got = (guard.get_data)(source, buffer, length);
    if got == u32::MAX {
        0
    } else {
        got
    }
}

/// 还没接上解码流时的占位实现（`Slot` 要求函数指针非空）
unsafe extern "system" fn no_data(_stream: u32, _buffer: *mut c_void, _length: u32) -> u32 {
    0
}

/// 当前输出走哪条路
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Output {
    /// `BASS_Init` 直接把曲目送到设备（DirectSound），跟随系统混音格式
    Shared,
    /// `BASS_Init(0)` 只解码，由 WASAPI 独占设备并按设备格式输出
    Exclusive,
}

struct Engine {
    api: Api,
    dir: PathBuf,
    wasapi: Option<wasapi::WasapiApi>,
    mix: Option<wasapi::MixApi>,
    slot: Arc<Mutex<Slot>>,
    output: Output,
    request_exclusive: bool,
    /// WASAPI 会话（设备 + 混音流）是否已建立
    session: bool,
    mixer: u32,
    out_info: Option<wasapi::WasapiInfo>,
    bass_ready: bool,
    stream: u32,
    path: Option<String>,
    volume: f32,
    /// 独占初始化失败的原因，用于设置页提示
    exclusive_note: String,
    /// 独占模式下进入 Stopped 的时刻，用于空闲后交还设备
    idle_since: Option<std::time::Instant>,
    /// 均衡器开关与 10 段增益（dB）
    eq_enabled: bool,
    eq_gains: Vec<f32>,
    /// 当前挂着的 FX 句柄，换曲 / 关开关时逐个移除
    eq_fx: Vec<u32>,
}

impl Engine {
    fn new() -> Result<Self> {
        let dir = dll_dir().ok_or_else(|| {
            anyhow!("未找到 bass.dll（应在 exe 同级目录或 third_party/bass/windows/x64）")
        })?;
        let api = unsafe { Api::load(&dir)? };
        let mut engine = Self {
            api,
            dir,
            wasapi: None,
            mix: None,
            slot: Arc::new(Mutex::new(Slot {
                stream: 0,
                mixer: 0,
                paused: false,
                get_data: no_data,
            })),
            output: Output::Shared,
            request_exclusive: false,
            session: false,
            mixer: 0,
            out_info: None,
            bass_ready: false,
            stream: 0,
            path: None,
            volume: 1.0,
            exclusive_note: String::new(),
            idle_since: None,
            eq_enabled: false,
            eq_gains: vec![0.0; EQ_CENTERS.len()],
            eq_fx: Vec::new(),
        };
        engine.slot.lock().expect("新建的锁不会中毒").get_data = engine.api.channel_get_data;
        engine.init_output()?;
        Ok(engine)
    }

    /* ------------------------------------------------------------ 输出 */

    /// 按 `request_exclusive` 建立输出；独占失败时回落共享并记下原因
    fn init_output(&mut self) -> Result<()> {
        if self.request_exclusive {
            match self.init_exclusive() {
                Ok(()) => return Ok(()),
                Err(error) => {
                    self.exclusive_note = error.to_string();
                    self.teardown_session();
                    self.free_bass();
                }
            }
        }
        self.init_shared()
    }

    fn init_shared(&mut self) -> Result<()> {
        self.free_bass();
        // -1 = 系统默认设备；0 = 无输出（CI/无声卡环境用 LAMP_BASS_DEVICE=0）
        let device = std::env::var("LAMP_BASS_DEVICE")
            .ok()
            .and_then(|v| v.parse::<i32>().ok())
            .unwrap_or(-1);
        let ok =
            unsafe { (self.api.init)(device, 44100, 0, std::ptr::null_mut(), std::ptr::null()) };
        if ok == 0 {
            bail!("BASS_Init 失败: {}", last_error(&self.api));
        }
        self.bass_ready = true;
        self.load_plugins();
        self.output = Output::Shared;
        EXCLUSIVE.store(false, Ordering::SeqCst);
        Ok(())
    }

    /// 只解码 + WASAPI 独占。设备按自身混音格式打开，素材交给 bassmix 重采样。
    fn init_exclusive(&mut self) -> Result<()> {
        self.free_bass();
        let ok = unsafe { (self.api.init)(0, 44100, 0, std::ptr::null_mut(), std::ptr::null()) };
        if ok == 0 {
            bail!("BASS_Init(0) 失败: {}", last_error(&self.api));
        }
        self.bass_ready = true;
        self.load_plugins();

        if self.wasapi.is_none() {
            self.wasapi = Some(unsafe { wasapi::WasapiApi::load(&self.dir)? });
        }
        if self.mix.is_none() {
            self.mix = Some(unsafe { wasapi::MixApi::load(&self.dir)? });
        }

        let user = Arc::as_ptr(&self.slot) as *mut c_void;
        // 0/0 = 设备混音格式，最容易被独占接受；不行再试常见格式
        let mut last = String::from("未尝试");
        let mut inited = false;
        for round in 0..2 {
            let mut busy = false;
            for (freq, chans) in [(0u32, 0u32), (48_000, 2), (44_100, 2)] {
                let ok = {
                    let wasapi = self.wasapi.as_ref().expect("已加载");
                    wasapi.init(
                        wasapi::InitConfig {
                            device: -1,
                            freq,
                            chans,
                            flags: wasapi::WASAPI_EXCLUSIVE,
                            buffer_secs: WASAPI_BUFFER_SECS,
                        },
                        wasapi_proc,
                        user,
                    )
                };
                if ok {
                    inited = true;
                    break;
                }
                busy = unsafe { (self.api.error_get_code)() } == BASS_ERROR_BUSY;
                last = last_error(&self.api);
            }
            if inited {
                break;
            }
            // 刚释放过设备时 WASAPI 可能还占着一小会儿，等一拍再试一次
            if !busy || round == 1 {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(150));
        }
        if !inited {
            bail!("设备不支持独占输出（{last}）");
        }

        let info = self
            .wasapi
            .as_ref()
            .and_then(|wasapi| wasapi.info())
            .ok_or_else(|| anyhow!("读取 WASAPI 设备信息失败"))?;
        self.out_info = Some(info);

        let mixer = {
            let mix = self.mix.as_ref().expect("已加载");
            mix.stream_create(
                info.freq,
                info.chans,
                BASS_SAMPLE_FLOAT | BASS_STREAM_DECODE,
            )
        };
        if mixer == 0 {
            bail!("创建混音流失败: {}", last_error(&self.api));
        }
        self.mixer = mixer;
        // 混音流是 44.1k/48k 素材与设备格式之间唯一的重采样点
        unsafe { (self.api.channel_set_attribute)(mixer, BASS_ATTRIB_SRC, SRC_QUALITY) };
        unsafe { (self.api.channel_set_attribute)(mixer, BASS_ATTRIB_VOL, self.volume) };

        let started = self
            .wasapi
            .as_ref()
            .map(|wasapi| wasapi.start())
            .unwrap_or(false);
        if !started {
            bail!("启动 WASAPI 失败: {}", last_error(&self.api));
        }

        self.session = true;
        self.output = Output::Exclusive;
        self.exclusive_note.clear();
        EXCLUSIVE.store(true, Ordering::SeqCst);
        Ok(())
    }

    fn load_plugins(&self) {
        for name in PLUGINS {
            let path = self.dir.join(name);
            if !path.is_file() {
                continue;
            }
            let wide = wide(&path);
            // 单个插件失败不影响整体，只是少了对应格式
            unsafe { (self.api.plugin_load)(wide.as_ptr(), BASS_UNICODE) };
        }
    }

    fn free_bass(&mut self) {
        if self.bass_ready {
            unsafe { (self.api.free)() };
            self.bass_ready = false;
        }
    }

    /// 释放 WASAPI 会话与混音流，设备交还系统
    fn teardown_session(&mut self) {
        self.set_slot(0, 0, true);
        if let Some(mix) = self.mix.as_ref() {
            if self.stream != 0 {
                mix.remove_channel(self.stream);
            }
        }
        if self.mixer != 0 {
            unsafe { (self.api.stream_free)(self.mixer) };
            self.mixer = 0;
        }
        if let Some(wasapi) = self.wasapi.as_ref() {
            wasapi.stop(true);
            wasapi.free();
        }
        self.session = false;
        self.out_info = None;
        EXCLUSIVE.store(false, Ordering::SeqCst);
    }

    /// 拆掉独占会话改用共享输出；`request_exclusive` 保持不变，
    /// 设置页仍能看到「请求独占但失败了」的原因
    fn fall_back_to_shared(&mut self) -> Result<()> {
        self.teardown_session();
        self.free_bass();
        self.init_shared()
    }

    /// 更新回调的取数源；`mixer` 为 0 时退回拉 `stream`（共享输出不走回调）
    fn set_slot(&self, stream: u32, mixer: u32, paused: bool) {
        if let Ok(mut slot) = self.slot.lock() {
            slot.stream = stream;
            slot.mixer = mixer;
            slot.paused = paused;
        }
    }

    fn set_slot_paused(&self, paused: bool) {
        if let Ok(mut slot) = self.slot.lock() {
            slot.paused = paused;
        }
    }

    fn slot_paused(&self) -> bool {
        self.slot.lock().map(|slot| slot.paused).unwrap_or(false)
    }

    /* ------------------------------------------------------------ 播放 */

    fn open_stream(&self, wide: &[u16]) -> Result<u32> {
        if self.output == Output::Exclusive {
            let handle = unsafe {
                (self.api.stream_create_file)(
                    0,
                    wide.as_ptr() as *const c_void,
                    0,
                    0,
                    decode_flags(),
                )
            };
            if handle == 0 {
                return Err(anyhow!("无法打开音频文件: {}", last_error(&self.api)));
            }
            let added = self
                .mix
                .as_ref()
                .map(|mix| mix.add_channel(self.mixer, handle, 0))
                .unwrap_or(false);
            if !added {
                let err = last_error(&self.api);
                unsafe { (self.api.stream_free)(handle) };
                return Err(anyhow!("无法挂到混音流: {err}"));
            }
            return Ok(handle);
        }

        // 32 位浮点样本：BASSFLAC 默认把 24/32 bit 无损素材压到 16 bit，
        // 24 bit 曲库因此白白丢掉一半精度。个别插件（如 WMA）不支持浮点，
        // 打开失败时退回整数流。
        let mut handle = unsafe {
            (self.api.stream_create_file)(
                0,
                wide.as_ptr() as *const c_void,
                0,
                0,
                stream_flags(true),
            )
        };
        if handle == 0 {
            handle = unsafe {
                (self.api.stream_create_file)(
                    0,
                    wide.as_ptr() as *const c_void,
                    0,
                    0,
                    stream_flags(false),
                )
            };
        }
        if handle == 0 {
            return Err(anyhow!("无法打开音频文件: {}", last_error(&self.api)));
        }
        Ok(handle)
    }

    fn play(&mut self, path: &str) -> Result<()> {
        if path.is_empty() {
            bail!("音频路径为空");
        }
        self.release_track();
        if self.output == Output::Exclusive && !self.session {
            if let Err(error) = self.init_exclusive() {
                // 设备被别的程序抢走等：回落共享继续放，别让用户点了没反应
                self.exclusive_note = error.to_string();
                self.fall_back_to_shared()?;
            }
        }

        let wide = wide(Path::new(path));
        let handle = match self.open_stream(&wide) {
            Ok(handle) => handle,
            // 独占下挂混音流失败（格式/设备状态异常）也回落一次
            Err(error) if self.output == Output::Exclusive => {
                self.exclusive_note = error.to_string();
                self.fall_back_to_shared()?;
                self.open_stream(&wide)?
            }
            Err(error) => return Err(error),
        };
        self.stream = handle;
        self.path = Some(path.to_string());

        if self.output == Output::Exclusive {
            // 音量与 SRC 都作用在混音流上：源流只是被拉取的数据源
            unsafe { (self.api.channel_set_attribute)(handle, BASS_ATTRIB_VOL, 1.0) };
            if self.mixer != 0 {
                unsafe {
                    (self.api.channel_set_attribute)(self.mixer, BASS_ATTRIB_VOL, self.volume)
                };
            }
            self.set_slot(handle, self.mixer, false);
            self.apply_eq();
        } else {
            // 音量是 per-channel 属性，换曲后必须重新应用
            unsafe { (self.api.channel_set_attribute)(handle, BASS_ATTRIB_VOL, self.volume) };
            // 采样率与设备不一致时才真正生效，一致时代价为零
            unsafe { (self.api.channel_set_attribute)(handle, BASS_ATTRIB_SRC, SRC_QUALITY) };
            if unsafe { (self.api.channel_play)(handle, 1) } == 0 {
                let err = last_error(&self.api);
                self.release_track();
                return Err(anyhow!("播放失败: {err}"));
            }
            // 新流没有旧 FX，重新挂一遍
            self.apply_eq();
        }
        store_state(State::Playing);
        Ok(())
    }

    fn pause(&mut self) -> Result<()> {
        self.ensure_stream()?;
        match self.output {
            Output::Shared => {
                if unsafe { (self.api.channel_pause)(self.stream) } == 0 {
                    return Err(anyhow!("暂停失败: {}", last_error(&self.api)));
                }
            }
            // 解码流没有“暂停”状态，停止拉取就是暂停
            Output::Exclusive => self.set_slot_paused(true),
        }
        store_state(State::Paused);
        Ok(())
    }

    fn resume(&mut self) -> Result<()> {
        self.ensure_stream()?;
        match self.output {
            Output::Shared => {
                if unsafe { (self.api.channel_play)(self.stream, 0) } == 0 {
                    return Err(anyhow!("继续播放失败: {}", last_error(&self.api)));
                }
            }
            Output::Exclusive => self.set_slot_paused(false),
        }
        store_state(State::Playing);
        Ok(())
    }

    fn stop(&mut self) -> Result<()> {
        self.idle_since = None;
        self.release_track();
        // 独占模式下设备一直被本进程占着，停止后要立刻交还
        if self.output == Output::Exclusive {
            self.teardown_session();
        }
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
        let ok = match self.output {
            // 源流挂在混音流上时必须走 bassmix 的接口
            Output::Exclusive => self
                .mix
                .as_ref()
                .map(|mix| mix.set_position(self.stream, bytes, BASS_POS_BYTE))
                .unwrap_or(false),
            Output::Shared => unsafe {
                (self.api.channel_set_position)(self.stream, bytes, BASS_POS_BYTE) != 0
            },
        };
        if !ok {
            return Err(anyhow!("跳转失败: {}", last_error(&self.api)));
        }
        Ok(())
    }

    fn set_volume(&mut self, volume: f32) -> Result<()> {
        // NaN 会穿透 clamp（clamp 对 NaN 返回 NaN），下发到 BASS 后音量永久变哑
        if !volume.is_finite() {
            bail!("音量非法: {volume}");
        }
        self.volume = volume.clamp(0.0, 1.0);
        let target = if self.output == Output::Exclusive {
            self.mixer
        } else {
            self.stream
        };
        if target != 0 {
            unsafe { (self.api.channel_set_attribute)(target, BASS_ATTRIB_VOL, self.volume) };
        }
        Ok(())
    }

    /* ------------------------------------------------------------ 均衡器 */

    /// 把 10 段均衡器挂到当前输出目标上（共享 = 曲目流，独占 = 混音流）
    fn apply_eq(&mut self) {
        let target = if self.output == Output::Exclusive {
            self.mixer
        } else {
            self.stream
        };
        self.clear_eq();
        if target == 0 || !self.eq_enabled {
            return;
        }
        let mut handles = Vec::with_capacity(EQ_CENTERS.len());
        for (index, center) in EQ_CENTERS.iter().enumerate() {
            let gain = self.eq_gains.get(index).copied().unwrap_or(0.0);
            // 0 dB 不挂 FX：10 个空转的滤波器纯属浪费 CPU
            if gain.abs() < 0.05 {
                continue;
            }
            let fx = unsafe { (self.api.channel_set_fx)(target, BASS_FX_DX8_PARAMEQ, 0) };
            if fx == 0 {
                continue;
            }
            let mut params = Dx8ParamEq {
                f_center: *center,
                f_bandwidth: EQ_BANDWIDTH,
                f_gain: gain,
            };
            let ok = unsafe {
                (self.api.fx_set_parameters)(fx, &mut params as *mut Dx8ParamEq as *mut c_void)
            };
            if ok == 0 {
                unsafe { (self.api.channel_remove_fx)(target, fx) };
                continue;
            }
            handles.push(fx);
        }
        self.eq_fx = handles;
    }

    /// 摘掉已挂的均衡器；目标流变了（换曲 / 拆会话）时只清句柄即可
    fn clear_eq(&mut self) {
        let target = if self.output == Output::Exclusive {
            self.mixer
        } else {
            self.stream
        };
        for fx in std::mem::take(&mut self.eq_fx) {
            if target != 0 {
                unsafe { (self.api.channel_remove_fx)(target, fx) };
            }
        }
    }

    /// 设置均衡器；`gains` 必须是 10 段（dB），超出 ±15 会被截断
    fn set_eq(&mut self, enabled: bool, gains: Vec<f32>) -> Result<()> {
        if gains.len() != EQ_CENTERS.len() {
            bail!(
                "均衡器需要 {} 段增益，收到 {} 段",
                EQ_CENTERS.len(),
                gains.len()
            );
        }
        if let Some(bad) = gains.iter().find(|gain| !gain.is_finite()) {
            bail!("均衡器增益非法: {bad}");
        }
        self.eq_enabled = enabled;
        self.eq_gains = gains
            .iter()
            .map(|gain| gain.clamp(-EQ_MAX_GAIN, EQ_MAX_GAIN))
            .collect();
        self.apply_eq();
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

    /// 曲目自然播完后把状态刷回 Stopped，并处理独占模式的空闲释放
    fn refresh(&mut self) {
        self.refresh_state();
        self.release_idle_session();
    }

    fn refresh_state(&self) {
        if self.stream == 0 {
            store_state(State::Stopped);
            return;
        }
        // 解码流不会因为暂停而改变 active 状态，暂停与否以 slot 为准
        if self.output == Output::Exclusive && self.slot_paused() {
            store_state(State::Paused);
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

    /// 独占模式下停了一会儿就把设备交还系统
    ///
    /// 播完队列后如果不放手，别的程序（浏览器、会议）会直接没声音；
    /// 暂停不计时，因为用户随时会继续，重建会话要几十毫秒。
    fn release_idle_session(&mut self) {
        if self.output != Output::Exclusive || !self.session {
            self.idle_since = None;
            return;
        }
        if state() != State::Stopped {
            self.idle_since = None;
            return;
        }
        let now = std::time::Instant::now();
        let since = *self.idle_since.get_or_insert(now);
        if now.duration_since(since) < idle_timeout() {
            return;
        }
        self.idle_since = None;
        self.release_track();
        self.teardown_session();
    }

    fn ensure_stream(&self) -> Result<()> {
        if self.stream == 0 {
            bail!("当前没有加载曲目");
        }
        Ok(())
    }

    fn release_track(&mut self) {
        if self.stream == 0 {
            store_state(State::Stopped);
            return;
        }
        let stream = self.stream;
        // 先让回调松手，再拆链路
        self.eq_fx.clear();
        self.set_slot(0, 0, true);
        self.stream = 0;
        self.path = None;
        match self.output {
            Output::Exclusive => {
                if let Some(mix) = self.mix.as_ref() {
                    mix.remove_channel(stream);
                }
                unsafe { (self.api.stream_free)(stream) };
            }
            Output::Shared => unsafe {
                (self.api.channel_stop)(stream);
                (self.api.stream_free)(stream);
            },
        }
        store_state(State::Stopped);
    }

    /// 切换输出模式：保留当前曲目、位置与播放状态
    fn set_exclusive(&mut self, exclusive: bool) -> Result<()> {
        let already = self.output
            == if exclusive {
                Output::Exclusive
            } else {
                Output::Shared
            };
        if self.request_exclusive == exclusive && already {
            return Ok(());
        }

        let was_playing = state() == State::Playing;
        let resume_at = self.position().unwrap_or(0.0);
        let path = self.path.clone();

        self.release_track();
        self.teardown_session();
        self.request_exclusive = exclusive;
        self.init_output()?;

        if let Some(path) = path {
            self.play(&path)?;
            if resume_at > 0.05 {
                self.seek(resume_at)?;
            }
            if !was_playing {
                self.pause()?;
            }
        }
        Ok(())
    }

    /// 设置页展示用：当前输出到底是怎么出声的
    fn output_info(&self) -> String {
        match self.output {
            Output::Exclusive => match self.out_info {
                Some(info) => {
                    let frame = (info.chans.max(1) * 4) as f32;
                    let secs = (info.buflen as f32 / frame) / info.freq.max(1) as f32;
                    format!(
                        "WASAPI 独占 · {} Hz · {} 声道 · {} · 缓冲 {:.0} ms",
                        info.freq,
                        info.chans,
                        info.format_label(),
                        secs * 1000.0
                    )
                }
                None => "WASAPI 独占（空闲已交还设备，播放时重新占用）".to_string(),
            },
            Output::Shared => {
                if self.request_exclusive {
                    format!("共享输出（独占失败：{}）", self.exclusive_note)
                } else {
                    "共享输出（跟随系统混音格式）".to_string()
                }
            }
        }
    }

    fn shutdown(&mut self) {
        self.release_track();
        self.teardown_session();
        self.free_bass();
    }
}

struct Shared {
    tx: Sender<Cmd>,
}

/// 引擎单例。
///
/// 刻意不用 `OnceLock<Result<..>>`：无声卡、DLL 缺失这类**可恢复**的失败
/// 会被永久缓存，用户插上耳机或补齐 DLL 之后必须重启进程。这里只在
/// 失败时记下原因，下次调用重新尝试启动。
static ENGINE: Mutex<Option<Result<Shared, String>>> = Mutex::new(None);

fn lock_engine() -> std::sync::MutexGuard<'static, Option<Result<Shared, String>>> {
    // 引擎锁只保护一个 Option，中毒说明上一次初始化 panic 了，仍可继续用
    ENGINE
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// 取引擎命令发送端；首次调用会拉起引擎线程。
fn sender() -> Result<Sender<Cmd>> {
    let mut guard = lock_engine();
    match guard.as_ref() {
        Some(Ok(shared)) => return Ok(shared.tx.clone()),
        // 上次失败：丢掉失败结果，重新试一次
        Some(Err(_)) => *guard = None,
        None => {}
    }
    match spawn() {
        Ok(shared) => {
            let tx = shared.tx.clone();
            *guard = Some(Ok(shared));
            Ok(tx)
        }
        Err(err) => {
            let message = err.to_string();
            *guard = Some(Err(message.clone()));
            Err(anyhow!("播放引擎不可用: {message}"))
        }
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
            Ok(Cmd::SetEq(enabled, gains, reply)) => {
                let _ = reply.send(engine.set_eq(enabled, gains));
            }
            Ok(Cmd::SetExclusive(exclusive, reply)) => {
                let _ = reply.send(engine.set_exclusive(exclusive));
            }
            Ok(Cmd::OutputInfo(reply)) => {
                let _ = reply.send(Ok(engine.output_info()));
            }
            Ok(Cmd::Shutdown(reply)) => {
                engine.shutdown();
                let _ = reply.send(Ok(()));
                return;
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

/// 单条命令的最长等待：引擎线程卡在打不开的文件（断连的 SMB、休眠中的移动盘）
/// 上时，`recv()` 会把 Dart 侧的 Future 永久挂起，UI 表现为整个播放区假死。
fn call_timeout() -> std::time::Duration {
    static TIMEOUT: OnceLock<std::time::Duration> = OnceLock::new();
    *TIMEOUT.get_or_init(|| {
        std::env::var("LAMP_ENGINE_TIMEOUT_SECS")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
            .map(std::time::Duration::from_secs)
            .unwrap_or(std::time::Duration::from_secs(10))
    })
}

fn call<T>(make: impl FnOnce(Reply<T>) -> Cmd) -> Result<T> {
    let sender = sender()?;
    let (tx, rx) = channel();
    sender
        .send(make(tx))
        .map_err(|_| anyhow!("播放引擎已退出"))?;
    match rx.recv_timeout(call_timeout()) {
        Ok(result) => result,
        Err(RecvTimeoutError::Timeout) => Err(anyhow!(
            "播放引擎无响应（超过 {} 秒），请检查文件所在磁盘是否可用",
            call_timeout().as_secs()
        )),
        Err(RecvTimeoutError::Disconnected) => Err(anyhow!("播放引擎无响应")),
    }
}

pub fn available() -> bool {
    if AVAILABLE.load(Ordering::SeqCst) {
        return true;
    }
    sender().is_ok()
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

pub fn is_exclusive() -> bool {
    EXCLUSIVE.load(Ordering::SeqCst)
}

pub fn set_exclusive(exclusive: bool) -> Result<()> {
    call(|reply| Cmd::SetExclusive(exclusive, reply))
}

pub fn set_eq(enabled: bool, gains: Vec<f32>) -> Result<()> {
    call(|reply| Cmd::SetEq(enabled, gains, reply))
}

pub fn output_info() -> Result<String> {
    call(Cmd::OutputInfo)
}

pub fn shutdown() -> Result<()> {
    // 不能走 sender()：那会在退出时反而把引擎启动起来
    let sender = {
        let guard = lock_engine();
        match guard.as_ref() {
            Some(Ok(shared)) => shared.tx.clone(),
            _ => return Ok(()),
        }
    };
    let (tx, rx) = channel();
    sender
        .send(Cmd::Shutdown(tx))
        .map_err(|_| anyhow!("播放引擎已退出"))?;
    // 设备释放不该把退出流程拖住
    let _ = rx.recv_timeout(std::time::Duration::from_secs(2));
    // 线程已退出：清空单例，让同一进程内还能重新拉起（测试与再次 init 都会用到）
    {
        let mut guard = lock_engine();
        *guard = None;
    }
    AVAILABLE.store(false, Ordering::SeqCst);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn float_stream_flags_keep_unicode_and_prescan() {
        let flags = stream_flags(true);
        assert_eq!(flags & BASS_UNICODE, BASS_UNICODE);
        assert_eq!(flags & BASS_STREAM_PRESCAN, BASS_STREAM_PRESCAN);
        assert_eq!(flags & BASS_SAMPLE_FLOAT, BASS_SAMPLE_FLOAT);
    }

    #[test]
    fn integer_stream_flags_have_no_float_bit() {
        assert_eq!(stream_flags(false) & BASS_SAMPLE_FLOAT, 0);
    }

    #[test]
    fn decode_flags_are_float_and_decoding() {
        let flags = decode_flags();
        assert_eq!(flags & BASS_STREAM_DECODE, BASS_STREAM_DECODE);
        assert_eq!(flags & BASS_SAMPLE_FLOAT, BASS_SAMPLE_FLOAT);
        assert_eq!(flags & BASS_UNICODE, BASS_UNICODE);
        assert_eq!(flags & BASS_STREAM_PRESCAN, BASS_STREAM_PRESCAN);
    }
}
