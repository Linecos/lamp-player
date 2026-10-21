import 'package:flutter/material.dart';

import 'routes.dart';
import '../theme/app_theme.dart';

/// 应用外壳：主题 + 路由 + 全局配置都收在这里。
///
/// 页面本身不写在此文件，新增页面请改 [LampRouter]。
class LampApp extends StatelessWidget {
  const LampApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lamp Player',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      initialRoute: AppRoutes.library,
      onGenerateRoute: LampRouter.onGenerateRoute,
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
  });

  final String message;

  /// 失败环节的描述，如「曲库未能打开」
  final String title;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lamp Player',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
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
