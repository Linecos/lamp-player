import 'package:flutter/material.dart';

/// 曲库页（首页）。
///
/// **当前是占位实现**：M1 落地后替换为真实曲库列表（见 docs/ROADMAP.md）。
/// 占位页不调用任何 Rust 接口，因此纯 Dart 环境下也能渲染，
/// `test/widget_test.dart` 正是用它做外壳冒烟测试。
class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Lamp Player')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.library_music_outlined,
              size: 56,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 12),
            Text('曲库尚未接入', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'M1：扫描目录 → 写入 SQLite → 列表展示',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
