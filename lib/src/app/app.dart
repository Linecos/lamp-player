import 'dart:async';

import 'package:flutter/material.dart';

import 'app_lifecycle.dart';
import 'routes.dart';
import 'theme_reveal.dart';
import 'title_bar.dart';
import 'tray_controller.dart';
import 'window_controls.dart';
import '../features/library/library_repository.dart';
import '../features/player/playback_service.dart';
import '../features/settings/theme_controller.dart';
import '../theme/app_theme.dart';

/// 应用外壳：主题 + 路由 + 全局配置都收在这里。
///
/// 页面本身不写在此文件，新增页面请改 [LampRouter]。
/// 数据源与播放能力可从外部注入，方便 widget 测试脱离 Rust 原生库。
/// 主题控制器也可注入：`main()` 会先恢复已保存的主题再挂载，避免启动闪烁。
class LampApp extends StatefulWidget {
  const LampApp({
    super.key,
    this.libraryRepository,
    this.playbackService,
    this.themeController,
    this.windowControls,
    this.lifecycle,
    this.trayController,
  });

  final LibraryRepository? libraryRepository;
  final PlaybackService? playbackService;

  /// 外部传入时由调用方负责生命周期（通常整个应用生命周期）；
  /// 不传时由 [LampApp] 自己创建并异步恢复。
  final ThemeController? themeController;

  /// 窗口控制（自绘标题栏用）；不传走真实的 `window_manager`。
  final WindowControls? windowControls;

  /// 应用级行为（关闭到托盘）；不传时设置页里的开关禁用
  final AppLifecycle? lifecycle;

  /// 托盘（关窗后播放控制用）；不传时托盘菜单只显示主窗口 / 退出
  final TrayController? trayController;

  @override
  State<LampApp> createState() => _LampAppState();
}

class _LampAppState extends State<LampApp> {
  late final ThemeController _theme;
  late final bool _ownsTheme;

  /// 自绘标题栏的窗口控制；测试可注入假实现
  late final WindowControls _windowControls =
      widget.windowControls ?? const WindowManagerControls();

  @override
  void initState() {
    super.initState();
    _ownsTheme = widget.themeController == null;
    _theme = widget.themeController ?? ThemeController();
    if (_ownsTheme) {
      unawaited(_theme.restore());
    }
  }

  @override
  void dispose() {
    if (_ownsTheme) {
      _theme.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ThemeScope(
      controller: _theme,
      child: ListenableBuilder(
        listenable: _theme,
        builder: (BuildContext context, Widget? child) {
          return MaterialApp(
            title: 'Lamp Player',
            debugShowCheckedModeBanner: false,
            // 强调色与调色板风格由设置决定：预设色板 / 系统强调色 / 跟随封面
            theme: AppTheme.light(
              _theme.effectiveSeed,
              variant: _theme.effectiveVariant,
              contrastLevel: _theme.highContrast ? 1.0 : 0.0,
            ),
            darkTheme: AppTheme.dark(
              _theme.effectiveSeed,
              variant: _theme.effectiveVariant,
              contrastLevel: _theme.highContrast ? 1.0 : 0.0,
            ),
            // 不用 MaterialApp 自带的 200ms ThemeData 过渡：那意味着每一帧换
            // 一次配色，而曲库页的分区快照是按「建快照那一刻的颜色」定死的，
            // 每换一次配色就要整页重建一次 —— 2000 首曲库上实测中位 24ms/帧、
            // 累计 1.4s，比瞬时切换贵 5 倍还多。主题照旧一帧切完，
            // 视觉上的渐变交给下面 builder 里的 [ThemeReveal]：它把切换前
            // 那一帧抓成图，从点击处画出一个不断变大的圆把它「挤掉」，
            // 过渡期间每帧只多一次 drawPath，不重建任何 widget。
            themeAnimationStyle: AnimationStyle.noAnimation,
            themeMode: _theme.mode,
            initialRoute: AppRoutes.library,
            // 自绘标题栏：原生标题栏已在 main.dart 里关掉；
            // 底色跟随曲库页，避免出现一条色带
            builder: (BuildContext context, Widget? child) => ThemeReveal(
              child: WindowChrome(
                controls: _windowControls,
                background: Theme.of(context).colorScheme.surfaceContainerLow,
                // 曲库页自己绘制顶栏、搜索框与拖动区，这里只保留右侧窗口按钮。
                overlay: true,
                controlsOnly: true,
                child: child ?? const SizedBox.shrink(),
              ),
            ),
            onGenerateRoute: (RouteSettings settings) =>
                LampRouter.onGenerateRoute(
                  settings,
                  repository: widget.libraryRepository,
                  playbackService: widget.playbackService,
                  lifecycle: widget.lifecycle,
                  trayController: widget.trayController,
                  windowControls: _windowControls,
                ),
          );
        },
      ),
    );
  }
}

/// 桥接初始化失败时的兜底界面。
///
/// 原生库加载失败（DLL 缺失、架构不匹配等）时 `runApp` 还没执行，
/// 直接用这个界面把原因显示出来，避免用户看到白屏。
class LampStartupErrorApp extends StatelessWidget {
  const LampStartupErrorApp({
    super.key,
    required this.message,
    this.title = '启动失败：Rust 核心未能加载',
    this.windowControls,
  });

  final String message;

  /// 失败环节的描述，如「曲库未能打开」
  final String title;

  /// 原生标题栏此时已隐藏，兜底页同样要给一个可拖动 / 可关闭的标题栏
  final WindowControls? windowControls;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lamp Player',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(AppTheme.defaultSeed),
      darkTheme: AppTheme.dark(AppTheme.defaultSeed),
      themeMode: ThemeMode.system,
      builder: (BuildContext context, Widget? child) => WindowChrome(
        controls: windowControls,
        background: Theme.of(context).scaffoldBackgroundColor,
        child: child ?? const SizedBox.shrink(),
      ),
      // Builder 是为了拿到 MaterialApp 提供的主题，而不是外层的默认主题
      home: Builder(
        builder: (BuildContext context) {
          final ThemeData theme = Theme.of(context);
          return Scaffold(
            appBar: AppBar(title: const Text('Lamp Player')),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      Icons.error_outline,
                      size: 56,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(height: 12),
                    Text(title, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    SelectableText(
                      message,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
