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
