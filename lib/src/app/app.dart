import 'dart:async';

import 'package:flutter/material.dart';

import 'app_lifecycle.dart';
import 'routes.dart';
import 'title_bar.dart';
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
            // 强调色与调色板风格由设置决定：预设色板或系统强调色（动态取色）
            theme: AppTheme.light(
              _theme.effectiveSeed,
              variant: _theme.schemeVariant,
              contrastLevel: _theme.highContrast ? 1.0 : 0.0,
            ),
            darkTheme: AppTheme.dark(
              _theme.effectiveSeed,
              variant: _theme.schemeVariant,
              contrastLevel: _theme.highContrast ? 1.0 : 0.0,
            ),
            themeMode: _theme.mode,
            initialRoute: AppRoutes.library,
            // 自绘标题栏：原生标题栏已在 main.dart 里关掉；
            // 底色跟随曲库页，避免出现一条色带
            builder: (BuildContext context, Widget? child) => WindowChrome(
              controls: _windowControls,
              background: Theme.of(context).colorScheme.surfaceContainerLow,
              // 曲库页自己把侧栏画到窗口顶部，标题条只保留拖动区和窗口按钮。
              overlay: true,
              child: child ?? const SizedBox.shrink(),
            ),
            onGenerateRoute: (RouteSettings settings) =>
                LampRouter.onGenerateRoute(
                  settings,
                  repository: widget.libraryRepository,
                  playbackService: widget.playbackService,
                  lifecycle: widget.lifecycle,
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
