#include "taskbar_manager.h"

#include <gdiplus.h>

#include <algorithm>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#ifndef WM_DWMSENDICONICTHUMBNAIL
#define WM_DWMSENDICONICTHUMBNAIL 0x0323
#endif
#ifndef WM_DWMSENDICONICLIVEPREVIEWBITMAP
#define WM_DWMSENDICONICLIVEPREVIEWBITMAP 0x0326
#endif
#ifndef PW_RENDERFULLCONTENT
#define PW_RENDERFULLCONTENT 0x00000002
#endif

namespace {

constexpr int kPrevButtonId = 101;
constexpr int kToggleButtonId = 102;
constexpr int kNextButtonId = 103;

constexpr int kIconPrev = 0;
constexpr int kIconToggle = 1;
constexpr int kIconNext = 2;

// 三个字形都在白色上画：任务栏按钮的底色由系统画（深色 / 浅色主题都一样），
// 所以图标本身只用纯白形状，不跟应用配色走
constexpr BYTE kIconAlpha = 255;

/// 诊断用：DWM 预览的收发记到 `%TEMP%\lamp_taskbar.log`（设 `LAMP_TASKBAR_LOG=1` 才开）
void LogTaskbar(const char* format, ...) {
  static const bool enabled = [] {
    wchar_t buf[8] = {};
    return GetEnvironmentVariableW(L"LAMP_TASKBAR_LOG", buf, 8) == 1 &&
           buf[0] == L'1';
  }();
  if (!enabled) return;

  char path[MAX_PATH] = {};
  if (GetTempPathA(MAX_PATH, path) == 0) return;
  strcat_s(path, "lamp_taskbar.log");
  FILE* file = nullptr;
  if (fopen_s(&file, path, "a") != 0 || file == nullptr) return;
  SYSTEMTIME now = {};
  GetLocalTime(&now);
  std::fprintf(file, "[%02d:%02d:%02d.%03d] ", now.wHour, now.wMinute,
               now.wSecond, now.wMilliseconds);
  va_list args;
  va_start(args, format);
  std::vfprintf(file, format, args);
  va_end(args);
  std::fputc('\n', file);
  std::fclose(file);
}

/// 32bpp 自顶向下 DIB（像素初始全 0）
HBITMAP CreateTopDownDib(int width, int height, void** out_bits) {
  BITMAPINFO info = {};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width;
  info.bmiHeader.biHeight = -height;  // 负高度 = 自顶向下
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;

  void* bits = nullptr;
  HBITMAP bitmap =
      CreateDIBSection(nullptr, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (bitmap == nullptr || bits == nullptr) {
    if (bitmap != nullptr) DeleteObject(bitmap);
    return nullptr;
  }
  if (out_bits != nullptr) *out_bits = bits;
  return bitmap;
}

/// PrintWindow 抓下来的画面不一定带 alpha（全 0 时 DWM 会整张当透明），
/// 有颜色没 alpha 就把 alpha 补成不透明；连颜色都没有说明根本没抓到
bool NormalizeCapturedAlpha(void* bits, int width, int height) {
  BYTE* pixels = static_cast<BYTE*>(bits);
  const size_t count =
      static_cast<size_t>(width) * static_cast<size_t>(height);

  bool has_alpha = false;
  bool has_color = false;
  for (size_t i = 0; i < count; ++i) {
    const BYTE* px = pixels + i * 4;
    if (px[3] != 0) {
      has_alpha = true;
      break;  // 有 alpha 直接放心用，不用再扫颜色
    }
    if (!has_color && (px[0] | px[1] | px[2]) != 0) has_color = true;
  }
  if (has_alpha) return true;
  if (!has_color) return false;

  for (size_t i = 0; i < count; ++i) pixels[i * 4 + 3] = 255;
  return true;
}

/// 抓窗口真实画面（DWM 的可见边界内），返回 32bpp DIB，调用方 DeleteObject
HBITMAP CaptureWindowDib(HWND hwnd) {
  RECT window_rect = {};
  if (!GetWindowRect(hwnd, &window_rect)) return nullptr;

  const int full_width = window_rect.right - window_rect.left;
  const int full_height = window_rect.bottom - window_rect.top;
  if (full_width <= 0 || full_height <= 0) return nullptr;

  // GetWindowRect 把窗口四周那圈看不见的拖拽边框也算进来了，
  // 用 DWM 的实际可见边界裁掉，预览图才不会多出一圈空白
  int crop_x = 0;
  int crop_y = 0;
  int crop_width = full_width;
  int crop_height = full_height;
  RECT frame_rect = {};
  if (SUCCEEDED(DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS,
                                      &frame_rect, sizeof(frame_rect)))) {
    const int x = frame_rect.left - window_rect.left;
    const int y = frame_rect.top - window_rect.top;
    const int w = frame_rect.right - frame_rect.left;
    const int h = frame_rect.bottom - frame_rect.top;
    if (x >= 0 && y >= 0 && w > 0 && h > 0 && x + w <= full_width &&
        y + h <= full_height) {
      crop_x = x;
      crop_y = y;
      crop_width = w;
      crop_height = h;
    }
  }

  HDC screen_dc = GetDC(nullptr);
  if (screen_dc == nullptr) return nullptr;
  HDC memory_dc = CreateCompatibleDC(screen_dc);
  ReleaseDC(nullptr, screen_dc);
  if (memory_dc == nullptr) return nullptr;

  void* full_bits = nullptr;
  HBITMAP full_bitmap =
      CreateTopDownDib(full_width, full_height, &full_bits);
  if (full_bitmap == nullptr) {
    DeleteDC(memory_dc);
    return nullptr;
  }

  HGDIOBJ old_object = SelectObject(memory_dc, full_bitmap);
  // PW_RENDERFULLCONTENT 让 DWM 交出合成后的画面；不带这个标志
  // 抓不到 Flutter(ANGLE/D3D) 硬件渲染的内容，只会得到一片空白
  const BOOL captured = PrintWindow(hwnd, memory_dc, PW_RENDERFULLCONTENT);
  SelectObject(memory_dc, old_object);
  DeleteDC(memory_dc);
  GdiFlush();

  if (!captured || !NormalizeCapturedAlpha(full_bits, full_width, full_height)) {
    DeleteObject(full_bitmap);
    return nullptr;
  }

  if (crop_width == full_width && crop_height == full_height) {
    return full_bitmap;
  }

  void* crop_bits = nullptr;
  HBITMAP crop_bitmap = CreateTopDownDib(crop_width, crop_height, &crop_bits);
  if (crop_bitmap == nullptr) return full_bitmap;  // 裁失败就用整窗画面兜底

  // 逐行拷：BitBlt 在 32bpp 之间不保证保留 alpha 通道
  const BYTE* source =
      static_cast<const BYTE*>(full_bits) +
      (static_cast<size_t>(crop_y) * static_cast<size_t>(full_width) +
       static_cast<size_t>(crop_x)) *
          4;
  BYTE* destination = static_cast<BYTE*>(crop_bits);
  for (int row = 0; row < crop_height; ++row) {
    memcpy(destination, source, static_cast<size_t>(crop_width) * 4);
    source += static_cast<size_t>(full_width) * 4;
    destination += static_cast<size_t>(crop_width) * 4;
  }

  DeleteObject(full_bitmap);
  return crop_bitmap;
}

}  // namespace

TaskbarManager& TaskbarManager::GetInstance() {
  static TaskbarManager instance;
  return instance;
}

TaskbarManager::TaskbarManager() {
  Gdiplus::GdiplusStartupInput input;
  gdiplus_started_ = Gdiplus::GdiplusStartup(&gdiplus_token_, &input, nullptr) ==
                     Gdiplus::Status::Ok;
}

TaskbarManager::~TaskbarManager() {
  // 先放掉封面再关 GDI+：Bitmap 的析构要用到 GDI+ 的活句柄
  cover_.reset();
  if (icon_prev_) DestroyIcon(icon_prev_);
  if (icon_play_) DestroyIcon(icon_play_);
  if (icon_pause_) DestroyIcon(icon_pause_);
  if (icon_next_) DestroyIcon(icon_next_);
  if (taskbar_list_) taskbar_list_->Release();
  if (gdiplus_started_) Gdiplus::GdiplusShutdown(gdiplus_token_);
}

void TaskbarManager::Init(HWND hwnd, flutter::BinaryMessenger* messenger) {
  hwnd_ = hwnd;
  // 任务栏就绪（或 Explorer 重启后）会广播这条注册消息
  wm_taskbar_button_created_ = RegisterWindowMessageW(L"TaskbarButtonCreated");
  CreateIcons();

  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "lamp_player/taskbar",
      &flutter::StandardMethodCodec::GetInstance());
  RegisterMethodChannel();

  // 平台线程上可能已经有人初始化过 COM：换个套间模型会返回
  // RPC_E_CHANGED_MODE，那就直接用现有的套间，不必也不能配对 Uninitialize
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  HRESULT hr = CoCreateInstance(CLSID_TaskbarList, nullptr,
                                CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&taskbar_list_));
  if (SUCCEEDED(hr) && taskbar_list_ != nullptr) {
    if (FAILED(taskbar_list_->HrInit())) {
      taskbar_list_->Release();
      taskbar_list_ = nullptr;
    }
  }
}

void TaskbarManager::RegisterMethodChannel() {
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const std::string& method = call.method_name();
        if (method == "clearCover") {
          ClearCover();
          result->Success();
          return;
        }
        if (method == "setCover") {
          const flutter::EncodableMap* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (args == nullptr) {
            result->Error("INVALID_ARGS", "setCover 需要 bytes");
            return;
          }
          auto it = args->find(flutter::EncodableValue("bytes"));
          if (it == args->end()) {
            result->Error("INVALID_ARGS", "setCover 需要 bytes");
            return;
          }
          const std::vector<uint8_t>* bytes =
              std::get_if<std::vector<uint8_t>>(&it->second);
          if (bytes == nullptr) {
            result->Error("INVALID_ARGS", "bytes 类型不对");
            return;
          }
          SetCover(*bytes);
          result->Success();
          return;
        }
        if (method != "setButtons") {
          result->NotImplemented();
          return;
        }
        const flutter::EncodableMap* args =
            std::get_if<flutter::EncodableMap>(call.arguments());
        bool playing = false;
        bool visible = true;
        if (args != nullptr) {
          auto it = args->find(flutter::EncodableValue("isPlaying"));
          if (it != args->end()) {
            const bool* value = std::get_if<bool>(&it->second);
            if (value != nullptr) playing = *value;
          }
          it = args->find(flutter::EncodableValue("visible"));
          if (it != args->end()) {
            const bool* value = std::get_if<bool>(&it->second);
            if (value != nullptr) visible = *value;
          }
        }
        is_playing_ = playing;
        visible_ = visible;
        has_request_ = true;
        ApplyButtons();
        result->Success();
      });
}

void TaskbarManager::ApplyButtons() {
  if (taskbar_list_ == nullptr || hwnd_ == nullptr) return;

  THUMBBUTTON buttons[3] = {};
  const THUMBBUTTONFLAGS flags = visible_ ? THBF_ENABLED : THBF_HIDDEN;

  buttons[0].dwMask = THB_ICON | THB_FLAGS | THB_TOOLTIP;
  buttons[0].iId = kPrevButtonId;
  buttons[0].hIcon = icon_prev_;
  buttons[0].dwFlags = flags;
  wcscpy_s(buttons[0].szTip, _countof(buttons[0].szTip), L"上一首");

  buttons[1].dwMask = THB_ICON | THB_FLAGS | THB_TOOLTIP;
  buttons[1].iId = kToggleButtonId;
  buttons[1].hIcon = is_playing_ ? icon_pause_ : icon_play_;
  buttons[1].dwFlags = flags;
  wcscpy_s(buttons[1].szTip, _countof(buttons[1].szTip),
           is_playing_ ? L"暂停" : L"播放");

  buttons[2].dwMask = THB_ICON | THB_FLAGS | THB_TOOLTIP;
  buttons[2].iId = kNextButtonId;
  buttons[2].hIcon = icon_next_;
  buttons[2].dwFlags = flags;
  wcscpy_s(buttons[2].szTip, _countof(buttons[2].szTip), L"下一首");

  if (!buttons_added_) {
    if (SUCCEEDED(taskbar_list_->ThumbBarAddButtons(hwnd_, 3, buttons))) {
      buttons_added_ = true;
    }
    return;
  }
  taskbar_list_->ThumbBarUpdateButtons(hwnd_, 3, buttons);
}

void TaskbarManager::CreateIcons() {
  icon_prev_ = MakeIcon(kIconPrev, false);
  icon_play_ = MakeIcon(kIconToggle, false);
  icon_pause_ = MakeIcon(kIconToggle, true);
  icon_next_ = MakeIcon(kIconNext, false);
}

HICON TaskbarManager::MakeIcon(int kind, bool paused) {
  int size = GetSystemMetrics(SM_CXSMICON);
  if (size <= 0) size = 20;

  Gdiplus::Bitmap bitmap(size, size, PixelFormat32bppARGB);
  Gdiplus::Graphics graphics(&bitmap);
  graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
  graphics.Clear(Gdiplus::Color(0, 0, 0, 0));

  Gdiplus::SolidBrush brush(Gdiplus::Color(kIconAlpha, 255, 255, 255));
  const Gdiplus::REAL w = static_cast<Gdiplus::REAL>(size);
  const Gdiplus::REAL h = static_cast<Gdiplus::REAL>(size);

  if (kind == kIconPrev) {
    const Gdiplus::PointF left[3] = {
        Gdiplus::PointF(w * 0.46f, h * 0.22f),
        Gdiplus::PointF(w * 0.10f, h * 0.50f),
        Gdiplus::PointF(w * 0.46f, h * 0.78f)};
    graphics.FillPolygon(&brush, left, 3);
    const Gdiplus::PointF right[3] = {
        Gdiplus::PointF(w * 0.86f, h * 0.22f),
        Gdiplus::PointF(w * 0.50f, h * 0.50f),
        Gdiplus::PointF(w * 0.86f, h * 0.78f)};
    graphics.FillPolygon(&brush, right, 3);
  } else if (kind == kIconToggle) {
    if (paused) {
      graphics.FillRectangle(&brush, w * 0.24f, h * 0.20f, w * 0.20f, h * 0.60f);
      graphics.FillRectangle(&brush, w * 0.56f, h * 0.20f, w * 0.20f, h * 0.60f);
    } else {
      const Gdiplus::PointF triangle[3] = {
          Gdiplus::PointF(w * 0.26f, h * 0.18f),
          Gdiplus::PointF(w * 0.84f, h * 0.50f),
          Gdiplus::PointF(w * 0.26f, h * 0.82f)};
      graphics.FillPolygon(&brush, triangle, 3);
    }
  } else {
    const Gdiplus::PointF left[3] = {
        Gdiplus::PointF(w * 0.14f, h * 0.22f),
        Gdiplus::PointF(w * 0.50f, h * 0.50f),
        Gdiplus::PointF(w * 0.14f, h * 0.78f)};
    graphics.FillPolygon(&brush, left, 3);
    const Gdiplus::PointF right[3] = {
        Gdiplus::PointF(w * 0.54f, h * 0.22f),
        Gdiplus::PointF(w * 0.90f, h * 0.50f),
        Gdiplus::PointF(w * 0.54f, h * 0.78f)};
    graphics.FillPolygon(&brush, right, 3);
  }

  HICON icon = nullptr;
  if (bitmap.GetHICON(&icon) != Gdiplus::Status::Ok) return nullptr;
  return icon;
}

void TaskbarManager::SetCover(const std::vector<uint8_t>& bytes) {
  if (bytes.empty() || hwnd_ == nullptr) return;

  // 走内存流解码而不是 `Bitmap::FromFile`：后者会把封面文件一直锁住，
  // 用户改封面 / 删文件时就被我们挡着了
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes.size());
  if (memory == nullptr) return;
  void* buffer = GlobalLock(memory);
  if (buffer == nullptr) {
    GlobalFree(memory);
    return;
  }
  memcpy(buffer, bytes.data(), bytes.size());
  GlobalUnlock(memory);

  IStream* stream = nullptr;
  if (CreateStreamOnHGlobal(memory, TRUE, &stream) != S_OK) {
    GlobalFree(memory);
    return;
  }
  std::unique_ptr<Gdiplus::Bitmap> decoded(
      new Gdiplus::Bitmap(stream, FALSE));
  stream->Release();
  if (decoded->GetLastStatus() != Gdiplus::Status::Ok) return;

  cover_ = std::move(decoded);
  // 有封面就让 DWM 按我们的位图出缩略图 / 预览；没有时恢复系统截图
  SetIconicPreview(true);
  DwmInvalidateIconicBitmaps(hwnd_);
  LogTaskbar("setCover bytes=%zu size=%dx%d", bytes.size(),
             cover_ ? static_cast<int>(cover_->GetWidth()) : 0,
             cover_ ? static_cast<int>(cover_->GetHeight()) : 0);
}

void TaskbarManager::ClearCover() {
  cover_.reset();
  LogTaskbar("clearCover");
  if (hwnd_ == nullptr) return;
  SetIconicPreview(false);
  DwmInvalidateIconicBitmaps(hwnd_);
}

void TaskbarManager::SetIconicPreview(bool enabled) {
  if (hwnd_ == nullptr) return;
  const BOOL value = enabled ? TRUE : FALSE;
  DwmSetWindowAttribute(hwnd_, DWMWA_FORCE_ICONIC_REPRESENTATION, &value,
                        sizeof(value));
  DwmSetWindowAttribute(hwnd_, DWMWA_HAS_ICONIC_BITMAP, &value,
                        sizeof(value));
}

HBITMAP TaskbarManager::RenderCover(int width, int height) {
  if (width <= 0 || height <= 0 || cover_ == nullptr) return nullptr;

  BITMAPINFO info = {};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width;
  info.bmiHeader.biHeight = -height;  // 负高度 = 自顶向下
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;

  void* bits = nullptr;
  HBITMAP bitmap_handle =
      CreateDIBSection(nullptr, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (bitmap_handle == nullptr || bits == nullptr) {
    if (bitmap_handle != nullptr) DeleteObject(bitmap_handle);
    return nullptr;
  }

  {
    Gdiplus::Bitmap canvas(width, height, width * 4, PixelFormat32bppARGB,
                           static_cast<BYTE*>(bits));
    Gdiplus::Graphics graphics(&canvas);
    // 整块铺满：调用方给的一定是正方形位图，所以这里没有留白，
    // 缩略图卡片按这张方图排版，四周不会空出没用的区域
    graphics.Clear(Gdiplus::Color(255, 26, 24, 22));
    graphics.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);

    // 源图按中心裁成正方再铺满整块（不拉伸）—— 非方图也不会变扁
    const Gdiplus::REAL source_w =
        static_cast<Gdiplus::REAL>(cover_->GetWidth());
    const Gdiplus::REAL source_h =
        static_cast<Gdiplus::REAL>(cover_->GetHeight());
    const Gdiplus::REAL source_side = (std::min)(source_w, source_h);
    const Gdiplus::REAL square_x = (source_w - source_side) / 2.0f;
    const Gdiplus::REAL square_y = (source_h - source_side) / 2.0f;
    graphics.DrawImage(
        cover_.get(),
        Gdiplus::RectF(0.0f, 0.0f, static_cast<Gdiplus::REAL>(width),
                       static_cast<Gdiplus::REAL>(height)),
        square_x, square_y, source_side, source_side,
        Gdiplus::UnitPixel);
  }

  GdiFlush();
  return bitmap_handle;
}

std::optional<LRESULT> TaskbarManager::HandleWindowMessage(HWND hwnd, UINT message,
                                                           WPARAM wparam,
                                                           LPARAM lparam) {
  if (wm_taskbar_button_created_ != 0 &&
      message == wm_taskbar_button_created_) {
    // 任务栏刚建好（或 Explorer 重启）：旧按钮已经跟着一起没了，重新 Add
    buttons_added_ = false;
    if (has_request_) ApplyButtons();
    return 0;
  }

  if (message == WM_COMMAND && HIWORD(wparam) == THBN_CLICKED) {
    const int id = LOWORD(wparam);
    const char* action = nullptr;
    if (id == kPrevButtonId) {
      action = "prev";
    } else if (id == kToggleButtonId) {
      action = "toggle";
    } else if (id == kNextButtonId) {
      action = "next";
    }
    if (action != nullptr && channel_) {
      channel_->InvokeMethod(
          "onButtonClick",
          std::make_unique<flutter::EncodableValue>(std::string(action)));
      return 0;
    }
  }

  // 系统要缩略图 / AeroPeek 预览：有封面就交方形封面，没有就让系统自己截图
  if (message == WM_DWMSENDICONICTHUMBNAIL) {
    // 注意打包顺序：**HIWORD 是最大宽、LOWORD 是最大高**（文档原文如此，
    // 与通常 (x, y) 的直觉相反）。弄反了渲染出来的位图会有一边超限，
    // DWM 直接 E_INVALIDARG 拒收，任务栏上就一直转圈等图。
    int max_width = HIWORD(lparam);
    int max_height = LOWORD(lparam);
    if (max_width <= 0) max_width = 200;
    if (max_height <= 0) max_height = 200;
    // 交正方形位图（取短边）：卡片按方图排版，图片就能填满，四周不留空
    const int side = (std::min)(max_width, max_height);
    HBITMAP bitmap = RenderCover(side, side);
    if (bitmap != nullptr) {
      const HRESULT hr = DwmSetIconicThumbnail(hwnd, bitmap, 0);
      DeleteObject(bitmap);
      LogTaskbar("thumb req max=%dx%d side=%d hr=%08lX", max_width, max_height,
                 side, hr);
      return 0;
    }
    LogTaskbar("thumb req max=%dx%d render failed (cover=%d)", max_width,
               max_height, cover_ != nullptr ? 1 : 0);
  }

  if (message == WM_DWMSENDICONICLIVEPREVIEWBITMAP) {
    // AeroPeek 大预览：窗口可见就抓真实画面
    // 只有最小化 / 抓不到时才退回封面
    if (!IsIconic(hwnd)) {
      HBITMAP captured = CaptureWindowDib(hwnd);
      if (captured != nullptr) {
        const HRESULT hr =
            DwmSetIconicLivePreviewBitmap(hwnd, captured, nullptr, 0);
        DeleteObject(captured);
        LogTaskbar("livepreview capture hr=%08lX", hr);
        return 0;
      }
      LogTaskbar("livepreview capture failed, fallback to cover");
    }

    RECT area = {};
    WINDOWPLACEMENT placement = {};
    placement.length = sizeof(WINDOWPLACEMENT);
    if (GetWindowPlacement(hwnd, &placement)) {
      area = placement.rcNormalPosition;
    } else if (!GetWindowRect(hwnd, &area)) {
      return std::nullopt;
    }
    const int window_width = area.right - area.left;
    const int window_height = area.bottom - area.top;
    // 最小化时：正方形封面摆在窗口正中
    const int side = (std::min)(window_width, window_height);
    HBITMAP bitmap = RenderCover(side, side);
    if (bitmap != nullptr) {
      POINT offset = {(window_width - side) / 2, (window_height - side) / 2};
      const HRESULT hr =
          DwmSetIconicLivePreviewBitmap(hwnd, bitmap, &offset, 0);
      DeleteObject(bitmap);
      LogTaskbar("livepreview cover window=%dx%d side=%d hr=%08lX",
                 window_width, window_height, side, hr);
      return 0;
    }
    LogTaskbar("livepreview %dx%d render failed", window_width, window_height);
  }

  // 任务栏会在窗口销毁时把按钮一起收走，其它消息不需要这里管
  if (message == WM_DESTROY && buttons_added_) {
    buttons_added_ = false;
  }
  (void)hwnd;
  (void)lparam;
  return std::nullopt;
}
