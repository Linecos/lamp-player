import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/app/immersive_chrome.dart';
import 'package:lamp_player/src/features/player/now_playing_page.dart';
import 'package:lamp_player/src/rust/api/lyrics.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

void main() {
  testWidgets('销毁播放页不会在树锁定期间改全局通知器', (WidgetTester tester) async {
    // 真机上窗口按钮那层用 AnimatedBuilder 盯着这个开关；dispose 发生在
    // finalizeTree 的 unmount 阶段（树锁着），直接改值就会抛
    // 「setState() called when widget tree was locked」。
    int chromeBuilds = 0;
    final ValueNotifier<NowPlayingData> data = ValueNotifier<NowPlayingData>(
      const NowPlayingData(),
    );
    addTearDown(data.dispose);
    addTearDown(() => pageOwnsWindowControls.value = false);

    await tester.pumpWidget(_harness(showPage: true, data: data, onBuild: () => chromeBuilds += 1));
    await tester.pumpAndSettle();
    expect(chromeBuilds, greaterThan(1), reason: '页面进来后开关应已置位');

    // 第二次 pump 只把页面摘出树：外层那个 AnimatedBuilder 的 Element 被复用、
    // 监听还在（真机上它就是 MaterialApp.builder 里的窗口按钮那层）。
    // 修复前这里会抛 widget-tree-locked。
    await tester.pumpWidget(_harness(showPage: false, data: data, onBuild: () => chromeBuilds += 1));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      pageOwnsWindowControls.value,
      isFalse,
      reason: '页面走了要交还窗口按钮（延迟到帧末执行）',
    );
  });
}

/// 外层常驻、只切换内层页面：模拟「窗口按钮那层一直活着」的真实结构
Widget _harness({
  required bool showPage,
  required ValueNotifier<NowPlayingData> data,
  required VoidCallback onBuild,
}) {
  return AnimatedBuilder(
    animation: pageOwnsWindowControls,
    builder: (BuildContext context, Widget? child) {
      onBuild();
      return MaterialApp(
        theme: AppTheme.light(AppTheme.defaultSeed),
        home: Scaffold(
          body: showPage
              ? NowPlayingPage(
                  data: data,
                  onTogglePlay: () async {},
                  onPrevious: () async {},
                  onNext: () async {},
                  onSeek: (double seconds) async {},
                  lyricsLoader: (String path) async => const TrackLyrics(
                    lines: <LyricLine>[],
                    plain: '',
                    source: 'none',
                  ),
                )
              : const SizedBox.expand(),
        ),
      );
    },
  );
}
