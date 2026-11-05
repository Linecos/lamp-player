//! Windows 实现：BASS 符号表、命令队列与共享 / 独占两条输出路径。
//!
//! 由 `bass.rs` 以 `#[path]` 声明为 `imp`，对外只通过父模块的公开函数访问。
//! 所有 BASS 调用都在同一条引擎线程上串行执行（命令队列 + 回执通道）。

use super::fft;
use super::wasapi;
use super::{Device, Progress, State};
use anyhow::{anyhow, bail, Result};
use std::ffi::c_void;
use std::path::{Path, PathBuf};

use super::api::{ansi_text, dll_dir, last_error, wide, Api, BassDeviceInfo};
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU8, Ordering};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;

/// 整曲响度分析（ReplayGain 2.0），独立于引擎线程
#[path = "analyze.rs"]
pub(super) mod analyze;

const ST_STOPPED: u8 = 0;
const ST_PLAYING: u8 = 1;
const ST_PAUSED: u8 = 2;

/// 独占模式下位置多久没前进就判定设备掉线。
///
/// 取 3 秒：正常解码一帧只有几十毫秒，网络盘上的大文件也远到不了这个量级，
/// 而用户拔线后 3 秒内就能看到回落，不至于以为播放器卡死了。
const EXCLUSIVE_STALL_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(3);

/// 状态轮询间隔，用于发现曲目自然播完
const TICK: std::time::Duration = std::time::Duration::from_millis(200);

/// 音量过渡的时长（毫秒）。
///
/// 暂停 / 停止的淡出与起播的淡入都用 500ms：再短就只是把硬切磨圆了一点，
/// 听不出「过渡」。定位用最短的，否则连拖进度条会听着像断续。
/// 淡出之后的真正暂停 / 停止按到期时刻精确补上（见 [`run`]），不再等 200ms 一拍。
const FADE_OUT_MS: u32 = 500;
const FADE_IN_MS: u32 = 500;
const SEEK_FADE_MS: u32 = 60;

/// 淡出结束后要补的动作
#[derive(Clone, Copy, PartialEq, Eq)]
enum FadeAction {
    Pause,
    Stop,
}

/// 同时等待淡出释放的旧流上限
///
/// 正常听歌永远到不了：8 秒淡变 + 每 200ms 切一次才会堆到 40 个。
/// 超过就强制释放最老的，宁可听感上硬切，也不让解码器与文件句柄无界累积。
const MAX_FADING: usize = 16;

static AVAILABLE: AtomicBool = AtomicBool::new(false);
static STATE: AtomicU8 = AtomicU8::new(ST_STOPPED);

/// 实际生效的输出是否为 WASAPI 独占（供 UI 同步读取）
static EXCLUSIVE: AtomicBool = AtomicBool::new(false);

/// 当前选中的共享输出设备（`-1` = 系统默认）
static DEVICE: AtomicI32 = AtomicI32::new(-1);

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
/// `BASS_DEVICEINFO.flags`：设备可用 / 系统默认设备
const BASS_DEVICE_ENABLED: u32 = 0x1;
const BASS_DEVICE_DEFAULT: u32 = 0x4000_0000;

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
pub(super) const PLUGINS: [&str; 5] = [
    "bassflac.dll",
    "bassopus.dll",
    "bass_aac.dll",
    "bassape.dll",
    "basswma.dll",
];

type Reply<T> = Sender<Result<T>>;

use super::SPECTRUM_BANDS;

/// 频谱异常只提示一次，避免每 33ms 刷屏
static SPECTRUM_FETCH_WARNED: AtomicBool = AtomicBool::new(false);
static SPECTRUM_SILENT_WARNED: AtomicBool = AtomicBool::new(false);

/// BASS 的 FFT 请求码：`BASS_DATA_FFT1024`（0x80000000 + 2）拿 512 个幅度值，
/// 叠加 `BASS_DATA_FFT_REMOVEDC` 去掉直流分量，否则整体会有一条偏置。
const BASS_DATA_FFT1024: u32 = 0x8000_0002;
const BASS_DATA_FFT_REMOVEDC: u32 = 0x40;

enum Cmd {
    Play(String, f64, Reply<()>),
    Pause(Reply<()>),
    Resume(Reply<()>),
    Stop(Reply<()>),
    Seek(f64, Reply<()>),
    Volume(f32, Reply<()>),
    /// 起播后补算出的 ReplayGain：更新 gain_db 并立即应用到当前输出
    SetGain(f64, Reply<()>),
    Snapshot(Reply<Progress>),
    /// 输出目标的当前音量（振幅），测试与诊断用
    OutputVolume(Reply<f32>),
    Spectrum(Reply<Vec<f32>>),
    Devices(Reply<Vec<Device>>),
    SetDevice(i32, Reply<()>),
    SetCrossfade(u32, Reply<()>),
    /// 音量过渡开关：播放 / 暂停 / 停止 / 定位时淡入淡出
    SetVolumeFade(bool, Reply<()>),
    SetEq(bool, Vec<f32>, Reply<()>),
    SetExclusive(bool, Reply<()>),
    OutputInfo(Reply<String>),
    Shutdown(Reply<()>),
}

/// 命令分类：同一类里后发的命令让先发的作废。
///
/// 引擎线程卡在打开文件上（断连的网络盘、休眠中的移动盘）时，排队的命令
/// 可能迟到好几秒：迟到的 `Play(A)` 会在用户已经切到 B 之后才真正执行，
/// 界面显示 B 却在放 A。序号 + 入队时刻就是用来丢掉这类过期命令的。
#[derive(Clone, Copy, PartialEq, Eq)]
enum Class {
    /// 换曲 / 暂停 / 继续 / 停止：只认最新的一条
    Transport,
    Seek,
    Volume,
    /// 均衡器 / 独占切换：都是整份状态覆盖，新的顶掉旧的
    Config,
    /// 查询与关闭：永不丢弃
    Passive,
}

impl Class {
    fn index(self) -> Option<usize> {
        match self {
            Class::Transport => Some(0),
            Class::Seek => Some(1),
            Class::Volume => Some(2),
            Class::Config => Some(3),
            Class::Passive => None,
        }
    }
}

/// 每类命令最近一次入队的序号
static LATEST: [std::sync::atomic::AtomicU64; 4] =
    [const { std::sync::atomic::AtomicU64::new(0) }; 4];
static NEXT_SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

/// 排队中的命令
struct Queued {
    seq: u64,
    class: Class,
    queued_at: std::time::Instant,
    cmd: Cmd,
}

impl Queued {
    /// 该丢弃时返回 `true`
    fn discarded(&self) -> bool {
        if self.class == Class::Passive {
            return false;
        }
        // 调用方已经等超时并拿到错误了：再执行只会让引擎状态比界面更「新」
        if self.queued_at.elapsed() > call_timeout() {
            return true;
        }
        match self.class.index() {
            Some(index) => self.seq < LATEST[index].load(Ordering::SeqCst),
            None => false,
        }
    }
}

impl Cmd {
    /// 丢掉的命令都回一个成功：调用方要的是「这条不再影响状态」，不是错误
    fn reply_discarded(self) {
        let reply = match self {
            Cmd::Play(_, _, reply)
            | Cmd::Pause(reply)
            | Cmd::Resume(reply)
            | Cmd::Stop(reply)
            | Cmd::Seek(_, reply)
            | Cmd::Volume(_, reply)
            | Cmd::SetEq(_, _, reply)
            | Cmd::SetExclusive(_, reply)
            | Cmd::SetVolumeFade(_, reply) => reply,
            _ => return,
        };
        let _ = reply.send(Ok(()));
    }
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
    /// 独占输出时回调抄下来的最近采样（已混成单声道），给频谱自己算 FFT。
    ///
    /// 不能让频谱去取混音流的 FFT —— 那是解码流，取数会把采样一起取走，
    /// 和这个回调抢数据（实测把播放拖成 1.64 倍速）。
    scope: Vec<f32>,
    scope_pos: usize,
    /// 设备通道数；0 表示还没建立会话
    scope_chans: u32,
}

/// 环形缓冲容量：4 帧 FFT，够 `scope_samples` 取最近一帧
const SCOPE_CAPACITY: usize = fft::FFT_SIZE * 4;

impl Slot {
    /// 把回调里的 PCM 抄一份进环形缓冲。
    ///
    /// 跑在 WAVEAPI 的实时回调线程上：只做加法和写入，不分配、不额外加锁
    /// （slot 的锁外面已经拿了）。
    fn push_scope(&mut self, buffer: *const c_void, bytes: u32) {
        let chans = self.scope_chans as usize;
        if chans == 0 {
            return;
        }
        // 一律按 float32 读：这份数据是本回调自己 `BASS_ChannelGetData` 从
        // 混音流取的，而混音流建的是 `BASS_SAMPLE_FLOAT`，格式是确定的。
        // 别看 `BASS_WASAPI_INFO.format` —— 它报的是设备原生格式（实测 32bit
        // 整数），但 BASS 实际交给回调的仍是 float，按它判断会把频谱判成 0。
        let frames = bytes as usize / (chans * 4);
        if frames == 0 {
            return;
        }
        let src = buffer as *const f32;
        let len = self.scope.len();
        let mut pos = self.scope_pos;
        for frame in 0..frames {
            let mut sum = 0.0f32;
            for chan in 0..chans {
                sum += unsafe { *src.add(frame * chans + chan) };
            }
            self.scope[pos] = sum / chans as f32;
            pos += 1;
            if pos == len {
                pos = 0;
            }
        }
        self.scope_pos = pos;
    }

    /// 最近 [`fft::FFT_SIZE`] 个采样，按时间先后排好
    fn scope_samples(&self) -> [f32; fft::FFT_SIZE] {
        let mut out = [0.0f32; fft::FFT_SIZE];
        let len = self.scope.len();
        if len == 0 {
            return out;
        }
        let start = (self.scope_pos + len - fft::FFT_SIZE.min(len)) % len;
        for (i, slot) in out.iter_mut().enumerate() {
            *slot = self.scope[(start + i) % len];
        }
        out
    }
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
    let mut guard = match slot.lock() {
        Ok(guard) => guard,
        Err(_) => {
            // 锁中毒时也要写静音：返回 0 会被 BASS 当成「输出结束」
            std::ptr::write_bytes(buffer as *mut u8, 0, length as usize);
            return length;
        }
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
    let get_data = guard.get_data;
    let got = get_data(source, buffer, length);
    if got == u32::MAX {
        return 0;
    }
    // 抄一份给频谱：必须在同一把锁里做，样本和 mixer 的位置才对得上
    guard.push_scope(buffer, got);
    got
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
    /// 音量过渡开关：播放淡入、暂停 / 停止淡出、定位前后淡变
    volume_fade: bool,
    /// 淡出结束后要补的动作（暂停 / 停止）；到点由 [`Engine::finish_fade`] 执行
    fade_pending: Option<(FadeAction, std::time::Instant)>,
    /// 独占初始化失败的原因，用于设置页提示
    exclusive_note: String,
    /// 独占模式下进入 Stopped 的时刻，用于空闲后交还设备
    idle_since: Option<std::time::Instant>,
    /// 共享输出设备索引（`-1` = 系统默认）
    device: i32,
    /// ReplayGain 曲目增益（dB，0 = 不调整），与音量相乘后下发
    gain_db: f64,
    /// 换曲交叉淡变时长（毫秒），0 = 直接切
    crossfade_ms: u32,
    /// 正在淡出的旧流与释放时刻
    ///
    /// 用列表而不是单个槽：连切 A→B→C 时 B 的记录不能把 A 的挤掉，
    /// 否则 A 的流句柄与解码资源要挂到 `BASS_Free` 才释放。
    fading: Vec<(u32, std::time::Instant)>,
    /// 均衡器开关与 10 段增益（dB）
    eq_enabled: bool,
    eq_gains: Vec<f32>,
    /// 当前挂着的 FX 句柄，换曲 / 关开关时逐个移除
    eq_fx: Vec<u32>,
    /// 自然播完后的末态：流已释放，但界面仍要显示「播到结尾」
    ended_position: f64,
    ended_duration: f64,
    /// 独占输出的停滞检测：最近一次「位置前进」的时刻与位置。
    ///
    /// 拔掉 USB DAC、设备被别的程序抢走时，回调不再被拉数据，但解码流的
    /// active 状态仍是 PLAYING —— 界面会显示「播放中」、进度冻住、也不会
    /// 自动下一首。位置连续几秒不动就判定设备掉线。
    stall_since: Option<std::time::Instant>,
    stall_position: f64,
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
                scope: vec![0.0; SCOPE_CAPACITY],
                scope_pos: 0,
                scope_chans: 0,
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
            // 默认开：本来就是用户要的「不要咔哒一声」
            volume_fade: true,
            fade_pending: None,
            exclusive_note: String::new(),
            idle_since: None,
            device: std::env::var("LAMP_BASS_DEVICE")
                .ok()
                .and_then(|value| value.parse::<i32>().ok())
                .unwrap_or(-1),
            gain_db: 0.0,
            crossfade_ms: 0,
            fading: Vec::new(),
            eq_enabled: false,
            eq_gains: vec![0.0; EQ_CENTERS.len()],
            eq_fx: Vec::new(),
            ended_position: 0.0,
            ended_duration: 0.0,
            stall_since: None,
            stall_position: 0.0,
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
        let ok = unsafe {
            (self.api.init)(
                self.device,
                44100,
                0,
                std::ptr::null_mut(),
                std::ptr::null(),
            )
        };
        if ok == 0 {
            let reason = last_error(&self.api);
            // 选中的设备被拔了：退回系统默认，别让整个引擎起不来
            if self.device > 0 {
                self.device = -1;
                if unsafe { (self.api.init)(-1, 44100, 0, std::ptr::null_mut(), std::ptr::null()) }
                    != 0
                {
                    self.bass_ready = true;
                    self.load_plugins();
                    self.output = Output::Shared;
                    self.exclusive_note =
                        format!("原输出设备不可用（{reason}），已改用系统默认设备");
                    DEVICE.store(-1, Ordering::SeqCst);
                    EXCLUSIVE.store(false, Ordering::SeqCst);
                    return Ok(());
                }
            }
            bail!("BASS_Init 失败: {reason}");
        }
        self.bass_ready = true;
        self.load_plugins();
        self.output = Output::Shared;
        DEVICE.store(self.device, Ordering::SeqCst);
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
        // 频谱要按设备格式去读回调里的 buffer：不是 float32 就先不抄，
        // 免得把整数采样当浮点解析出一堆噪声
        if let Ok(mut slot) = self.slot.lock() {
            slot.scope_chans = info.chans;
            slot.scope_pos = 0;
        }
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
        // FX 句柄挂在混音流上，先摘掉再释放：BASS 句柄会复用，
        // 留着不清理，下次 clear_eq 可能误删复用后的句柄
        self.clear_eq();
        if let Some(mix) = self.mix.as_ref() {
            if self.stream != 0 {
                mix.remove_channel(self.stream);
            }
        }
        if self.mixer != 0 {
            unsafe { (self.api.stream_free)(self.mixer) };
            self.mixer = 0;
        }
        if let Ok(mut slot) = self.slot.lock() {
            slot.scope_chans = 0;
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

    fn play(&mut self, path: &str, replay_gain_db: f64) -> Result<()> {
        if path.is_empty() {
            bail!("音频路径为空");
        }
        // 增益属于曲目：换曲时一起更新，之后调音量仍然带着它
        self.gain_db = if replay_gain_db.is_finite() {
            replay_gain_db.clamp(-24.0, 12.0)
        } else {
            0.0
        };
        // 新曲目开始：上一首的末态位置作废
        self.ended_position = 0.0;
        self.ended_duration = 0.0;
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
        // 交叉淡变只在共享模式做：独占模式的输出是一条混音流，
        // 两条源流重叠要再加一条混音通道，收益不抵复杂度（那里只做淡入）。
        let fade_ms = self.crossfade_ms;
        let overlap = fade_ms > 0 && self.output == Output::Shared && self.stream != 0;
        if overlap {
            let old = self.stream;
            self.stream = 0;
            self.path = None;
            self.eq_fx.clear();
            self.fade_out(old, fade_ms);
        } else {
            self.release_track();
        }
        self.stream = handle;
        self.path = Some(path.to_string());
        let target = self.target_volume();
        // 新曲从 0 拉起来：交叉淡变有旧曲垫着，没有交叉时靠音量过渡补一个淡入
        let fade_in_ms = if overlap {
            fade_ms
        } else if self.volume_fade {
            FADE_IN_MS
        } else {
            0
        };

        if self.output == Output::Exclusive {
            // 音量与 SRC 都作用在混音流上：源流只是被拉取的数据源
            unsafe { (self.api.channel_set_attribute)(handle, BASS_ATTRIB_VOL, 1.0) };
            if self.mixer != 0 {
                let start = if fade_in_ms > 0 { 0.0 } else { target };
                unsafe { (self.api.channel_set_attribute)(self.mixer, BASS_ATTRIB_VOL, start) };
                if fade_in_ms > 0 {
                    unsafe {
                        (self.api.channel_slide_attribute)(
                            self.mixer,
                            BASS_ATTRIB_VOL,
                            target,
                            fade_in_ms,
                        )
                    };
                }
            }
            self.set_slot(handle, self.mixer, false);
            self.apply_eq();
        } else {
            // 音量是 per-channel 属性，换曲后必须重新应用
            let start = if fade_in_ms > 0 { 0.0 } else { target };
            unsafe { (self.api.channel_set_attribute)(handle, BASS_ATTRIB_VOL, start) };
            // 采样率与设备不一致时才真正生效，一致时代价为零
            unsafe { (self.api.channel_set_attribute)(handle, BASS_ATTRIB_SRC, SRC_QUALITY) };
            if unsafe { (self.api.channel_play)(handle, 1) } == 0 {
                let err = last_error(&self.api);
                self.release_track();
                return Err(anyhow!("播放失败: {err}"));
            }
            if fade_in_ms > 0 {
                unsafe {
                    (self.api.channel_slide_attribute)(handle, BASS_ATTRIB_VOL, target, fade_in_ms)
                };
            }
            // 新流没有旧 FX，重新挂一遍
            self.apply_eq();
        }
        // 新曲上台：上一首的暂停淡出不该再补刀
        self.fade_pending = None;
        store_state(State::Playing);
        Ok(())
    }

    /// 旧流淡出，到点由 [`Engine::reap_fading`] 释放
    fn fade_out(&mut self, stream: u32, millis: u32) {
        unsafe { (self.api.channel_slide_attribute)(stream, BASS_ATTRIB_VOL, 0.0, millis) };
        self.fading.push((
            stream,
            std::time::Instant::now() + std::time::Duration::from_millis(millis as u64),
        ));
    }

    /// 用户音量 × ReplayGain，下发到输出目标的实际振幅
    fn target_volume(&self) -> f32 {
        let factor = if self.gain_db == 0.0 {
            1.0
        } else {
            10f32.powf((self.gain_db / 20.0) as f32)
        };
        (self.volume * factor).clamp(0.0, 4.0)
    }

    /// 把音量写到当前输出目标上（共享 = 曲目流，独占 = 混音流）
    fn apply_volume(&self) {
        self.set_output_volume(self.target_volume());
    }

    fn pause(&mut self) -> Result<()> {
        self.ensure_stream()?;
        // 先淡出，到点再真正暂停（[`Engine::finish_fade`]）
        // 状态立刻置成暂停，界面与听觉都不会觉得慢
        if self.begin_fade(FadeAction::Pause) {
            store_state(State::Paused);
            return Ok(());
        }
        self.pause_now()
    }

    fn pause_now(&mut self) -> Result<()> {
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
        // 淡出途中又点了播放：取消那次暂停，音量滑回去
        self.fade_pending = None;
        match self.output {
            Output::Shared => {
                if unsafe { (self.api.channel_play)(self.stream, 0) } == 0 {
                    return Err(anyhow!("继续播放失败: {}", last_error(&self.api)));
                }
            }
            Output::Exclusive => self.set_slot_paused(false),
        }
        if self.volume_fade {
            let target = self.target_volume();
            self.slide_output_volume(target, FADE_IN_MS);
        }
        store_state(State::Playing);
        Ok(())
    }

    fn stop(&mut self) -> Result<()> {
        // 同样先淡出再释放流：直接 release 也是硬切
        if self.begin_fade(FadeAction::Stop) {
            self.idle_since = None;
            // 主动停止不是「播到结尾」，进度回到 0
            self.ended_position = 0.0;
            self.ended_duration = 0.0;
            store_state(State::Stopped);
            return Ok(());
        }
        self.stop_now()
    }

    fn stop_now(&mut self) -> Result<()> {
        self.idle_since = None;
        self.release_track();
        // 主动停止不是「播到结尾」，进度回到 0
        self.ended_position = 0.0;
        self.ended_duration = 0.0;
        // 独占模式下设备一直被本进程占着，停止后要立刻交还
        if self.output == Output::Exclusive {
            self.teardown_session();
        }
        Ok(())
    }

    /// 开始淡出；返回 `true` 表示淡出已启动，调用方不要再立即执行动作。
    ///
    /// 不淡的情况：开关关着、没有流、状态不是播放中、本来就没声音。
    fn begin_fade(&mut self, action: FadeAction) -> bool {
        if !self.volume_fade || self.stream == 0 || self.fade_pending.is_some() {
            return false;
        }
        if state() != State::Playing {
            return false;
        }
        // 已经静音（启动预加载就是静音起播）：没有声音可淡，直接收尾
        if self.target_volume() <= 0.0 {
            return false;
        }
        if !self.slide_output_volume(0.0, FADE_OUT_MS) {
            return false;
        }
        self.fade_pending = Some((
            action,
            std::time::Instant::now() + std::time::Duration::from_millis(FADE_OUT_MS as u64),
        ));
        true
    }

    /// 到点补上淡出之后的动作；由 [`Engine::refresh`] 调用。
    ///
    /// 引擎线程在淡出期间按到期时刻唤醒，所以这里几乎不会迟到。
    fn finish_fade(&mut self) {
        let Some((action, due)) = self.fade_pending else {
            return;
        };
        if std::time::Instant::now() < due {
            return;
        }
        self.fade_pending = None;
        let result = match action {
            FadeAction::Pause => self.pause_now(),
            FadeAction::Stop => self.stop_now(),
        };
        if let Err(error) = result {
            eprintln!("音量过渡收尾失败：{error}");
        }
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
        // 跳转的爆音来自波形不连续：先把音量按到 0，跳完再淡回来。
        // 这里必须**瞬间**静音，不能 slide——否则跳转会发生在淡出完成之前。
        let fade = self.volume_fade && state() == State::Playing;
        let target = self.target_volume();
        if fade {
            self.set_output_volume(0.0);
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
            // 跳失败也别把声音留在 0
            if fade {
                self.set_output_volume(target);
            }
            return Err(anyhow!("跳转失败: {}", last_error(&self.api)));
        }
        if fade {
            self.slide_output_volume(target, SEEK_FADE_MS);
        }
        Ok(())
    }

    fn set_volume(&mut self, volume: f32) -> Result<()> {
        // NaN 会穿透 clamp（clamp 对 NaN 返回 NaN），下发到 BASS 后音量永久变哑
        if !volume.is_finite() {
            bail!("音量非法: {volume}");
        }
        self.volume = volume.clamp(0.0, 1.0);
        // 淡出途中改音量不能把声音拉回来：输出让那次淡出走完，
        // 新音量由续播的淡入带出来
        let fading = self.fade_pending.is_some();
        if !fading {
            self.apply_volume();
        }
        Ok(())
    }

    /// 起播后补算出的 ReplayGain：更新增益并立即作用到正在出的声上。
    ///
    /// gain_db 会在下一次 [`Engine::play`] 被入参覆盖，所以这里只管「现在这首」；
    /// 过期值（用户已切歌）由 Dart 侧过滤，这里不校验曲目身份。
    fn set_gain(&mut self, gain_db: f64) -> Result<()> {
        if !gain_db.is_finite() {
            bail!("增益非法: {gain_db}");
        }
        self.gain_db = gain_db.clamp(-24.0, 12.0);
        // 与 set_volume 同理：淡出途中不把声音拉回来
        if self.fade_pending.is_none() {
            self.apply_volume();
        }
        Ok(())
    }

    /* -------------------------------------------------------- 音量过渡 */

    /// 开 / 关音量过渡；关掉时把可能挂着的那次淡出立刻收尾，
    /// 否则音量会停在 0。
    fn set_volume_fade(&mut self, enabled: bool) {
        self.volume_fade = enabled;
        if enabled {
            return;
        }
        if let Some((action, _)) = self.fade_pending.take() {
            let result = match action {
                FadeAction::Pause => self.pause_now(),
                FadeAction::Stop => self.stop_now(),
            };
            if let Err(error) = result {
                eprintln!("关闭音量过渡时收尾失败：{error}");
            }
        }
    }

    /// 当前音量作用在哪个句柄上（独占 = 混音流，共享 = 曲目流）
    fn output_target(&self) -> u32 {
        if self.output == Output::Exclusive {
            self.mixer
        } else {
            self.stream
        }
    }

    /// 立即把输出音量设成 [value]（振幅）
    fn set_output_volume(&self, value: f32) {
        let target = self.output_target();
        if target != 0 {
            unsafe { (self.api.channel_set_attribute)(target, BASS_ATTRIB_VOL, value) };
        }
    }

    /// 在 [millis] 毫秒内把输出音量滑到 [value]；返回是否成功下发
    fn slide_output_volume(&self, value: f32, millis: u32) -> bool {
        let target = self.output_target();
        if target == 0 || millis == 0 {
            return false;
        }
        unsafe { (self.api.channel_slide_attribute)(target, BASS_ATTRIB_VOL, value, millis) != 0 }
    }

    /// 输出目标的当前音量（振幅）；没有流时为 0
    fn output_volume(&self) -> f32 {
        let target = self.output_target();
        if target == 0 {
            return 0.0;
        }
        let mut value = 0.0f32;
        unsafe { (self.api.channel_get_attribute)(target, BASS_ATTRIB_VOL, &mut value) };
        value
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
        // 停止的淡出还没收尾时，界面已经停在 0 了：别报淡出点的位置
        if matches!(self.fade_pending, Some((FadeAction::Stop, _))) {
            return Ok(0.0);
        }
        if self.stream == 0 {
            // 自然播完后流已释放，返回记录下来的末态位置
            return Ok(self.ended_position);
        }
        let bytes = unsafe { (self.api.channel_get_position)(self.stream, BASS_POS_BYTE) };
        Ok(unsafe { (self.api.channel_bytes2seconds)(self.stream, bytes) })
    }

    fn duration(&self) -> Result<f64> {
        if self.stream == 0 {
            return Ok(self.ended_duration);
        }
        let bytes = unsafe { (self.api.channel_get_length)(self.stream, BASS_POS_BYTE) };
        Ok(unsafe { (self.api.channel_bytes2seconds)(self.stream, bytes) })
    }

    fn snapshot(&self) -> Result<Progress> {
        Ok(Progress {
            position: self.position()?,
            duration: self.duration()?,
        })
    }

    /// 当前输出的对数分频频谱（[`SPECTRUM_BANDS`] 段，0~1）。
    ///
    /// 通道要和 `wasapi_proc` 取数据时一致：独占模式下源流没经过混音器，
    /// 直接对源流做 FFT 会和实际听到的声音不一致。
    fn spectrum(&self) -> Vec<f32> {
        let channel = if self.mixer != 0 {
            self.mixer
        } else {
            self.stream
        };
        // 只在第一次异常时打一行日志：频谱全零最难查，得知道是「取不到」
        // 还是「取到了但真是 0」——前者多半是独占模式或通道已释放
        let mut bands = vec![0.0f32; SPECTRUM_BANDS];
        // 用真实播放状态判断，而不是 slot.paused：后者只在独占模式维护，
        // 独占里暂停过再切回共享输出时它会一直是 true，频谱就永远全零
        if channel == 0 || state() != State::Playing {
            return bands;
        }
        // 独占输出下 mixer 是**解码流**（BASS_STREAM_DECODE），对它取 FFT 会把
        // 采样一起取走、解码位置跟着前进；而 wasapi_proc 正是从同一条流里拉
        // 数据喂给设备。两边抢一条解码流 → 输出欠载：播放变快（实测 1.64x）、
        // 还带电流声。共享输出没这问题，因为那时 mixer 为 0，频谱走的是普通
        // 播放流（有播放缓冲，FFT 不推进位置）。
        //
        // 所以独占改走「回调抄样本 + 自己算 FFT」这条路（[`Slot::push_scope`]）。
        if self.mixer != 0 && self.output == Output::Exclusive {
            return self.scope_spectrum();
        }
        let mut fft = [0.0f32; 512];
        let got = unsafe {
            (self.api.channel_get_data)(
                channel,
                fft.as_mut_ptr().cast(),
                BASS_DATA_FFT1024 | BASS_DATA_FFT_REMOVEDC,
            )
        };
        if got == u32::MAX || got == 0 {
            if !SPECTRUM_FETCH_WARNED.swap(true, Ordering::Relaxed) {
                eprintln!(
                    "[频谱] BASS_ChannelGetData 取数失败：got={got} channel={channel} \
                     mixer={} stream={} paused={} err={}",
                    self.mixer,
                    self.stream,
                    self.slot_paused(),
                    last_error(&self.api),
                );
            }
            return bands;
        }
        let bins = (got as usize).min(fft.len());
        bands_from(&fft[..bins], &mut bands);
        if bands.iter().all(|value| *value < 0.001)
            && !SPECTRUM_SILENT_WARNED.swap(true, Ordering::Relaxed)
        {
            eprintln!(
                "[频谱] 一帧全零：channel={channel} mixer={} 独占={} bin(首段)={:.6}",
                self.mixer,
                self.mixer != 0,
                fft[1],
            );
        }
        bands
    }

    /// 独占输出的频谱：从回调抄下来的样本里自己算，完全不碰音频流
    fn scope_spectrum(&self) -> Vec<f32> {
        let mut bands = vec![0.0f32; SPECTRUM_BANDS];
        // try_lock 而不是 lock：拿不到说明音频线程正在写（时间极短），这一帧
        // 干脆不要 —— 反过来让音频线程等我们，就可能变成爆音
        let Ok(slot) = self.slot.try_lock() else {
            return bands;
        };
        let samples = slot.scope_samples();
        drop(slot);
        let fft = fft::magnitude(&samples);
        bands_from(&fft, &mut bands);
        bands
    }

    /// 释放淡出已结束的旧流：播下一首时它还在出声，不能立刻拆
    ///
    /// 每 tick 调一次。连切时列表里可能同时挂着多个（8 秒淡变极端情况下几十个），
    /// 超过 [`MAX_FADING`] 就先释放最老的，不让解码资源无界累积。
    fn reap_fading(&mut self) {
        if self.fading.is_empty() {
            return;
        }
        let now = std::time::Instant::now();
        let pending = std::mem::take(&mut self.fading);
        let mut expired: Vec<u32> = Vec::new();
        let mut keep: Vec<(u32, std::time::Instant)> = Vec::with_capacity(pending.len());
        for entry in pending {
            if now >= entry.1 {
                expired.push(entry.0);
            } else {
                keep.push(entry);
            }
        }
        // 保持 push 顺序，越靠前越早入队
        while keep.len() > MAX_FADING {
            expired.push(keep.remove(0).0);
        }
        self.fading = keep;
        for stream in expired {
            unsafe {
                (self.api.channel_stop)(stream);
                (self.api.stream_free)(stream);
            }
        }
    }

    /// 曲目自然播完后把状态刷回 Stopped，并处理独占模式的空闲释放
    fn refresh(&mut self) {
        // 淡出到点就把暂停 / 停止补上（要跑在 refresh_state 之前，
        // 否则这一拍还会把状态读回 Playing）
        self.finish_fade();
        self.reap_fading();
        self.refresh_state();
        // 独占设备掉线：接口状态仍是 PLAYING，但位置不再前进
        self.check_output_stall();
        // 自然播完就释放流：挂着不放手会把文件句柄占住，Explorer 删 / 改名、
        // 「从曲库移除」后的删文件都会失败。
        // 暂停不会被误判：共享模式只有 STOPPED 才算结束（PAUSED ≠ 0），
        // 独占用位置判断，暂停时位置不在末尾
        if self.stream != 0 && self.decode_ended() {
            self.finish_track();
        }
        self.release_idle_session();
    }

    /// 独占输出的停滞检测：位置连续 [`EXCLUSIVE_STALL_TIMEOUT`] 没前进就
    /// 认为设备已经掉了（拔线 / 被别的程序独占），回落到共享输出继续放。
    fn check_output_stall(&mut self) {
        if self.output != Output::Exclusive || self.stream == 0 || self.slot_paused() {
            self.stall_since = None;
            return;
        }
        let position = self.position().unwrap_or(0.0);
        let duration = self.duration().unwrap_or(0.0);
        // 已经播到结尾：那是正常结束，交给 decode_ended / finish_track
        if duration > 0.0 && position >= duration - 0.1 {
            self.stall_since = None;
            return;
        }
        if (position - self.stall_position).abs() >= 0.05 {
            self.stall_position = position;
            self.stall_since = Some(std::time::Instant::now());
            return;
        }
        let since = *self.stall_since.get_or_insert_with(std::time::Instant::now);
        if since.elapsed() >= EXCLUSIVE_STALL_TIMEOUT {
            self.recover_from_stall();
        }
    }

    /// 设备掉线后回落共享输出，尽量保住播放位置与播放状态
    fn recover_from_stall(&mut self) {
        let resume_at = self.position().unwrap_or(0.0);
        let was_playing = state() == State::Playing;
        let path = self.path.clone();

        self.stall_since = None;
        self.release_track();
        self.teardown_session();
        // 设备都没了，别再尝试独占：共享输出至少还能出声
        self.request_exclusive = false;
        self.output = Output::Shared;
        if let Err(error) = self.init_output() {
            eprintln!("独占设备掉线后回落共享失败：{error}");
            self.exclusive_note = format!("设备已断开，回落共享也失败：{error}");
            return;
        }
        self.exclusive_note = "输出设备已断开，已回落到共享输出".to_string();
        if let Some(path) = path {
            if let Err(error) = self.play(&path, self.gain_db) {
                eprintln!("掉线后用共享输出重开曲目失败：{error}");
                return;
            }
            if resume_at > 0.05 {
                if let Err(error) = self.seek(resume_at) {
                    eprintln!("掉线后用共享输出跳回 {resume_at:.1}s 失败：{error}");
                }
            }
            if !was_playing {
                if let Err(error) = self.pause() {
                    eprintln!("掉线恢复后没能保持暂停：{error}");
                }
            }
        }
    }

    /// 解码流是否已经播到结尾
    fn decode_ended(&self) -> bool {
        if self.stream == 0 {
            return false;
        }
        match self.output {
            Output::Exclusive => {
                let duration = self.duration().unwrap_or(0.0);
                let position = self.position().unwrap_or(0.0);
                duration > 0.0 && position >= duration - 0.1
            }
            Output::Shared => {
                // 只有 STOPPED 才是播完；PAUSED / PAUSED_DEVICE 不能释放流，
                // 否则暂停后 seek / resume 会报「没有加载曲目」
                unsafe { (self.api.channel_is_active)(self.stream) == 0 }
            }
        }
    }

    /// 记录末态并释放流，界面仍能显示「播到结尾」
    fn finish_track(&mut self) {
        self.ended_duration = self.duration().unwrap_or(0.0);
        self.ended_position = self.ended_duration;
        self.release_track();
        store_state(State::Stopped);
    }

    fn refresh_state(&self) {
        // 淡出期间状态由调用方（暂停 / 停止）定，别被这里的 active 覆盖回 Playing
        if self.fade_pending.is_some() {
            return;
        }
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
        for (stream, _) in std::mem::take(&mut self.fading) {
            unsafe {
                (self.api.channel_stop)(stream);
                (self.api.stream_free)(stream);
            }
        }
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
            let gain = self.gain_db;
            self.play(&path, gain)?;
            if resume_at > 0.05 {
                self.seek(resume_at)?;
            }
            if !was_playing {
                self.pause()?;
            }
        }
        Ok(())
    }

    /// 枚举可用输出设备（共享模式）；索引从 1 开始，0 是「无输出」伪设备
    fn devices(&self) -> Result<Vec<Device>> {
        let mut list = Vec::new();
        let mut info = BassDeviceInfo::default();
        for index in 1..64 {
            let ok = unsafe { (self.api.get_device_info)(index, &mut info) };
            if ok == 0 {
                break;
            }
            if info.flags & BASS_DEVICE_ENABLED == 0 {
                continue;
            }
            let is_default =
                index == self.device || (self.device < 0 && info.flags & BASS_DEVICE_DEFAULT != 0);
            list.push(Device {
                index,
                name: ansi_text(info.name),
                is_default,
            });
        }
        Ok(list)
    }

    /// 切换共享输出设备：保留当前曲目、位置与播放状态
    fn set_device(&mut self, index: i32) -> Result<()> {
        let index = index.max(-1);
        if index == self.device && self.bass_ready {
            return Ok(());
        }
        let was_playing = state() == State::Playing;
        let resume_at = self.position().unwrap_or(0.0);
        let path = self.path.clone();
        let gain = self.gain_db;

        self.release_track();
        self.teardown_session();
        self.device = index;
        // 换设备后独占可能换了张卡，旧的原因说明作废
        self.exclusive_note.clear();
        self.init_output()?;

        if let Some(path) = path {
            self.play(&path, gain)?;
            if resume_at > 0.05 {
                self.seek(resume_at)?;
            }
            if !was_playing {
                self.pause()?;
            }
        }
        Ok(())
    }

    /// 换曲交叉淡变时长（毫秒）；0 关闭
    fn set_crossfade(&mut self, millis: u32) {
        self.crossfade_ms = millis.min(20_000);
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
                if !self.exclusive_note.is_empty() {
                    // 两种情况共用这段：独占初始化失败、或独占设备中途掉线
                    format!("共享输出（{}）", self.exclusive_note)
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
    tx: Sender<Queued>,
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
fn sender() -> Result<Sender<Queued>> {
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
    let (tx, rx) = channel::<Queued>();
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

fn run(mut engine: Engine, rx: Receiver<Queued>) {
    loop {
        // 淡出期间按到期时刻精确唤醒：多等一拍会让暂停后进度条继续往前走
        let timeout = engine
            .fade_pending
            .map(|(_, due)| due.saturating_duration_since(std::time::Instant::now()))
            .unwrap_or(TICK)
            .min(TICK);
        match rx.recv_timeout(timeout) {
            Ok(queued) => {
                if queued.discarded() {
                    queued.cmd.reply_discarded();
                } else if dispatch(&mut engine, queued.cmd) {
                    return;
                }
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

/// 执行一条命令；返回 `true` 表示引擎线程该退出了
fn dispatch(engine: &mut Engine, cmd: Cmd) -> bool {
    match cmd {
        Cmd::Play(path, gain_db, reply) => {
            let _ = reply.send(engine.play(&path, gain_db));
        }
        Cmd::Pause(reply) => {
            let _ = reply.send(engine.pause());
        }
        Cmd::Resume(reply) => {
            let _ = reply.send(engine.resume());
        }
        Cmd::Stop(reply) => {
            let _ = reply.send(engine.stop());
        }
        Cmd::Seek(secs, reply) => {
            let _ = reply.send(engine.seek(secs));
        }
        Cmd::Volume(volume, reply) => {
            let _ = reply.send(engine.set_volume(volume));
        }
        Cmd::SetGain(gain_db, reply) => {
            let _ = reply.send(engine.set_gain(gain_db));
        }
        Cmd::Snapshot(reply) => {
            let _ = reply.send(engine.snapshot());
        }
        Cmd::OutputVolume(reply) => {
            let _ = reply.send(Ok(engine.output_volume()));
        }
        Cmd::Spectrum(reply) => {
            let _ = reply.send(Ok(engine.spectrum()));
        }
        Cmd::Devices(reply) => {
            let _ = reply.send(engine.devices());
        }
        Cmd::SetDevice(index, reply) => {
            let _ = reply.send(engine.set_device(index));
        }
        Cmd::SetCrossfade(millis, reply) => {
            engine.set_crossfade(millis);
            let _ = reply.send(Ok(()));
        }
        Cmd::SetEq(enabled, gains, reply) => {
            let _ = reply.send(engine.set_eq(enabled, gains));
        }
        Cmd::SetVolumeFade(enabled, reply) => {
            engine.set_volume_fade(enabled);
            let _ = reply.send(Ok(()));
        }
        Cmd::SetExclusive(exclusive, reply) => {
            let _ = reply.send(engine.set_exclusive(exclusive));
        }
        Cmd::OutputInfo(reply) => {
            let _ = reply.send(Ok(engine.output_info()));
        }
        Cmd::Shutdown(reply) => {
            engine.shutdown();
            let _ = reply.send(Ok(()));
            return true;
        }
    }
    false
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

fn call<T>(class: Class, make: impl FnOnce(Reply<T>) -> Cmd) -> Result<T> {
    let sender = sender()?;
    let seq = NEXT_SEQ.fetch_add(1, Ordering::SeqCst);
    if let Some(index) = class.index() {
        // 入队即登记：后来的命令让还在排队的同类作废
        LATEST[index].store(seq, Ordering::SeqCst);
    }
    let (tx, rx) = channel();
    sender
        .send(Queued {
            seq,
            class,
            queued_at: std::time::Instant::now(),
            cmd: make(tx),
        })
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

pub fn play(path: &str, replay_gain_db: f64) -> Result<()> {
    call(Class::Transport, |reply| {
        Cmd::Play(path.to_string(), replay_gain_db, reply)
    })
}

pub fn analyze_gain(path: &str) -> Result<f64> {
    analyze::analyze_gain(path)
}

pub fn devices() -> Result<Vec<Device>> {
    call(Class::Passive, Cmd::Devices)
}

pub fn set_device(index: i32) -> Result<()> {
    call(Class::Config, |reply| Cmd::SetDevice(index, reply))
}

pub fn current_device() -> i32 {
    DEVICE.load(Ordering::SeqCst)
}

pub fn set_crossfade(millis: u32) -> Result<()> {
    call(Class::Config, |reply| Cmd::SetCrossfade(millis, reply))
}

/// 开 / 关音量过渡（暂停淡出、起播淡入、定位前后淡变）。
pub fn set_volume_fade(enabled: bool) -> Result<()> {
    call(Class::Config, |reply| Cmd::SetVolumeFade(enabled, reply))
}

pub fn pause() -> Result<()> {
    call(Class::Transport, Cmd::Pause)
}

pub fn resume() -> Result<()> {
    call(Class::Transport, Cmd::Resume)
}

pub fn stop() -> Result<()> {
    call(Class::Transport, Cmd::Stop)
}

pub fn seek(position_secs: f64) -> Result<()> {
    call(Class::Seek, |reply| Cmd::Seek(position_secs, reply))
}

pub fn set_volume(volume: f64) -> Result<()> {
    call(Class::Volume, |reply| Cmd::Volume(volume as f32, reply))
}

/// 应用起播后补算出的 ReplayGain 增益（dB），立即作用到当前输出。
///
/// 走 Volume 类：连发几条时只认最新，与音量滑条同一套作废逻辑。
pub fn set_replay_gain(gain_db: f64) -> Result<()> {
    call(Class::Volume, |reply| Cmd::SetGain(gain_db, reply))
}

/// 第 [index] 条分频边界落在哪个 bin 上（对数分布：低频密、高频疏）
/// 幅度谱 → [`SPECTRUM_BANDS`] 段的 0~1 值。
///
/// BASS 的 FFT 和 [`fft::magnitude`] 输出同量纲（满幅正弦 = 1），所以两条路
/// 共用这一套对数分频与高频提升。
fn bands_from(fft: &[f32], bands: &mut [f32]) {
    let bins = fft.len();
    if bins == 0 {
        return;
    }
    for (index, band) in bands.iter_mut().enumerate() {
        let low = spectrum_edge(index, bins);
        let high = spectrum_edge(index + 1, bins).max(low + 1).min(bins);
        let peak = fft[low..high]
            .iter()
            .fold(0.0f32, |acc, value| acc.max(*value));
        // 高频能量天然偏低，做一点提升，否则右半边永远贴地平线
        let lift = 0.75 + 1.5 * (index as f32 / SPECTRUM_BANDS as f32);
        *band = (peak.sqrt() * lift).clamp(0.0, 1.0);
    }
}

fn spectrum_edge(index: usize, bins: usize) -> usize {
    let ratio = index as f32 / SPECTRUM_BANDS as f32;
    ((bins as f32).powf(ratio) as usize).clamp(1, bins - 1)
}

pub fn snapshot() -> Result<Progress> {
    call(Class::Passive, Cmd::Snapshot)
}

/// 输出目标的当前音量（振幅）；测试与诊断用，没有流时为 0
pub fn output_volume() -> Result<f32> {
    call(Class::Passive, Cmd::OutputVolume)
}

/// 频谱快照（[`SPECTRUM_BANDS`] 段，0~1）；没有在放歌时全是 0。
pub fn spectrum() -> Result<Vec<f32>> {
    call(Class::Passive, Cmd::Spectrum)
}

pub fn position() -> Result<f64> {
    snapshot().map(|progress| progress.position)
}

pub fn duration() -> Result<f64> {
    snapshot().map(|progress| progress.duration)
}

pub fn is_exclusive() -> bool {
    EXCLUSIVE.load(Ordering::SeqCst)
}

pub fn set_exclusive(exclusive: bool) -> Result<()> {
    call(Class::Config, |reply| Cmd::SetExclusive(exclusive, reply))
}

pub fn set_eq(enabled: bool, gains: Vec<f32>) -> Result<()> {
    call(Class::Config, |reply| Cmd::SetEq(enabled, gains, reply))
}

pub fn output_info() -> Result<String> {
    call(Class::Passive, Cmd::OutputInfo)
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
        .send(Queued {
            seq: NEXT_SEQ.fetch_add(1, Ordering::SeqCst),
            class: Class::Passive,
            queued_at: std::time::Instant::now(),
            cmd: Cmd::Shutdown(tx),
        })
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

    /// 构造一条排队命令；`age` 用来模拟「已经在队列里躺了很久」
    fn queued(class: Class, seq: u64, age: std::time::Duration) -> Queued {
        let now = std::time::Instant::now();
        Queued {
            seq,
            class,
            queued_at: now.checked_sub(age).unwrap_or(now),
            cmd: Cmd::Pause(channel().0),
        }
    }

    /// 下面几个用例改的是进程级 `LATEST`：并行跑会互相覆盖（曾经偶发红），必须串行
    static SEQ_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn seq_guard() -> std::sync::MutexGuard<'static, ()> {
        SEQ_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    #[test]
    fn newer_transport_command_supersedes_older_queued_one() {
        let _guard = seq_guard();
        let seq = NEXT_SEQ.fetch_add(10, Ordering::SeqCst);
        LATEST[0].store(seq, Ordering::SeqCst);
        assert!(
            queued(Class::Transport, seq - 1, std::time::Duration::ZERO).discarded(),
            "排在前面的换曲命令应作废"
        );
        assert!(
            !queued(Class::Transport, seq, std::time::Duration::ZERO).discarded(),
            "最新那条要执行"
        );
    }

    #[test]
    fn passive_commands_are_never_discarded() {
        let _guard = seq_guard();
        let seq = NEXT_SEQ.fetch_add(10, Ordering::SeqCst);
        LATEST[0].store(seq + 5, Ordering::SeqCst);
        assert!(
            !queued(Class::Passive, seq, std::time::Duration::ZERO).discarded(),
            "查询与关闭命令不参与作废"
        );
    }

    #[test]
    fn command_that_waited_past_the_timeout_is_dropped() {
        let _guard = seq_guard();
        let seq = NEXT_SEQ.fetch_add(10, Ordering::SeqCst);
        // Seek 类：序号是最新的，只按「等太久」判定
        LATEST[1].store(seq, Ordering::SeqCst);
        let expired = call_timeout() + std::time::Duration::from_secs(1);
        assert!(
            queued(Class::Seek, seq, expired).discarded(),
            "调用方早已放弃等待，这条不该再生效"
        );
    }
}
