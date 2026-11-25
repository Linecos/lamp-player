#pragma once

#include <dwmapi.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <gdiplus.h>
#include <shobjidl.h>
#include <windows.h>

#include <cstdint>
#include <memory>
#include <optional>
#include <vector>

// 任务栏缩略图工具栏：鼠标悬停任务栏图标时浮出的 上一首 / 播放暂停 / 下一首。
//
// 走 ITaskbarList3（`ThumbBarAddButtons` / `ThumbBarUpdateButtons`）。两条约束：
// - Add 只能成功一次，之后换图标一律走 Update；
// - Explorer 重启或任务栏还没建好时会发来 `TaskbarButtonCreated`，那时必须把
//   `buttons_added_` 置回 false 重新 Add，否则按钮再也不出现。
//
// 点击从 `WM_COMMAND`（`HIWORD(wparam) == THBN_CLICKED`）回来，转成 MethodChannel
// 调用 `onButtonClick('prev' | 'toggle' | 'next')` 交给 Dart 走播放那套逻辑。
class TaskbarManager {
 public:
  static TaskbarManager& GetInstance();

  void Init(HWND hwnd, flutter::BinaryMessenger* messenger);

  /// 返回有值表示这条消息已被工具栏消费，调用方不要再往下派发
  std::optional<LRESULT> HandleWindowMessage(HWND hwnd, UINT message,
                                            WPARAM wparam, LPARAM lparam);

 private:
  TaskbarManager();
  ~TaskbarManager();
  TaskbarManager(const TaskbarManager&) = delete;
  TaskbarManager& operator=(const TaskbarManager&) = delete;

  void RegisterMethodChannel();
  void ApplyButtons();
  void CreateIcons();
  HICON MakeIcon(int kind, bool paused);

  /// 换 / 撤任务栏预览图：有封面时悬停看到的是方形封面，没有就退回窗口截图
  void SetCover(const std::vector<uint8_t>& bytes);
  void ClearCover();
  void SetIconicPreview(bool enabled);

  /// 把封面中心裁成正方、铺满 [width]×[height] 位图（调用方传正方形尺寸），
  /// 返回的 HBITMAP 归调用方 DeleteObject
  HBITMAP RenderCover(int width, int height);

  HWND hwnd_ = nullptr;
  ITaskbarList3* taskbar_list_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;

  /// 当前曲目的封面（DWM 只在收到 WM_DWMSENDICONIC* 时才要位图，所以留一份原图）
  std::unique_ptr<Gdiplus::Bitmap> cover_;

  /// `RegisterWindowMessage("TaskbarButtonCreated")` 的返回值，0 表示注册失败
  UINT wm_taskbar_button_created_ = 0;
  bool buttons_added_ = false;
  bool gdiplus_started_ = false;
  ULONG_PTR gdiplus_token_ = 0;

  /// 最后一次请求的状态：任务栏还没就绪时先记着，等 Created 消息到了再应用
  bool is_playing_ = false;
  bool visible_ = false;
  bool has_request_ = false;

  // 图标在 Init 里一次建好、之后只换句柄：已注册的按钮如果拿到被销毁的 HICON，
  // 任务栏会画出空白
  HICON icon_prev_ = nullptr;
  HICON icon_play_ = nullptr;
  HICON icon_pause_ = nullptr;
  HICON icon_next_ = nullptr;
};
