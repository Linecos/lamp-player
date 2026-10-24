import 'package:flutter/material.dart';

import 'app_lifecycle.dart';
import '../features/library/library_page.dart';
import '../features/library/library_repository.dart';
import '../features/player/playback_service.dart';

/// 路由名称常量。
///
/// 新增页面时：先在这里加一个常量，再到 [LampRouter.onGenerateRoute] 加一个 case。
/// 页面之间一律通过这些常量跳转，不要在别处硬编码字符串。
abstract final class AppRoutes {
  /// 曲库首页
  static const String library = '/';

  // 例：
  // static const String settings = '/settings';
}

/// 全局路由分发。
///
/// 加页面只需要改这个 switch，不会碰到其它页面的代码，便于并行开发。
/// [repository] / [playbackService] 仅用于测试注入，生产环境传空走 Rust。
abstract final class LampRouter {
  static Route<void>? onGenerateRoute(
    RouteSettings settings, {
    LibraryRepository? repository,
    PlaybackService? playbackService,
    AppLifecycle? lifecycle,
  }) {
    switch (settings.name) {
      case AppRoutes.library:
        return MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => LibraryPage(
            repository: repository,
            playbackService: playbackService,
            appLifecycle: lifecycle,
          ),
        );
      default:
        // 未登记的路由返回 null，Flutter 会直接抛错，便于尽早发现路由名拼错
        return null;
    }
  }
}
