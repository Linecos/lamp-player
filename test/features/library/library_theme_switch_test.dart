import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/library/library_page.dart';
import 'package:lamp_player/src/rust/api/model.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

import '../../support/fake_library.dart';

/// 分区快照会把「整棵已建好的 widget」原样复用，页面在快照里直接写的
/// `Text(style: theme.textTheme.…)` 于是停在建快照那一刻的颜色上。
/// 切深浅色后标题 / 副标题就成了上一种主题色（浅色下的近白字、深色下的浅灰字）。
void main() {
  Future<void> pumpSwitching(
    WidgetTester tester,
    ValueNotifier<Brightness> brightness,
    FakeLibraryRepository repository,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ValueListenableBuilder<Brightness>(
        valueListenable: brightness,
        builder: (BuildContext context, Brightness value, Widget? child) {
          return MaterialApp(
            theme: AppTheme.light(AppTheme.defaultSeed),
            darkTheme: AppTheme.dark(AppTheme.defaultSeed),
            themeMode: value == Brightness.dark
                ? ThemeMode.dark
                : ThemeMode.light,
            home: LibraryPage(
              repository: repository,
              playbackService: FakePlaybackService(),
              sessionStore: FakeSessionStore(),
            ),
          );
        },
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
  }

  testWidgets('切到深色后，分区标题与副标题换成新主题色', (WidgetTester tester) async {
    final FakeLibraryRepository repository = FakeLibraryRepository(
      tracks: <Track>[
        sampleTrack(title: '夜航', album: '夜之专辑'),
        sampleTrack(title: '潮汐', album: '玻璃海', durationSecs: 200),
      ],
    );
    final ValueNotifier<Brightness> brightness = ValueNotifier<Brightness>(
      Brightness.light,
    );
    addTearDown(brightness.dispose);

    await pumpSwitching(tester, brightness, repository);

    // 侧栏导航里也有一个「音乐」，只看内容卡片里的那一份
    Finder inCard(String text) => find.descendant(
      of: find.byKey(const ValueKey<String>('section-fade')),
      matching: find.text(text),
    );

    final Color lightTitle = tester.widget<Text>(inCard('音乐')).style!.color!;
    final Color lightSubtitle = tester
        .widget<Text>(inCard('2 首音乐'))
        .style!
        .color!;
    expect(
      lightTitle,
      AppTheme.light(AppTheme.defaultSeed).colorScheme.onSurface,
    );
    expect(
      lightSubtitle,
      AppTheme.light(AppTheme.defaultSeed).colorScheme.onSurfaceVariant,
    );

    brightness.value = Brightness.dark;
    await tester.pump();
    await tester.pumpAndSettle();

    final Color darkTitle = tester.widget<Text>(inCard('音乐')).style!.color!;
    final Color darkSubtitle = tester
        .widget<Text>(inCard('2 首音乐'))
        .style!
        .color!;
    expect(
      darkTitle,
      AppTheme.dark(AppTheme.defaultSeed).colorScheme.onSurface,
      reason: '标题必须换成深色主题的 onSurface，否则在深底上几乎看不见',
    );
    expect(
      darkSubtitle,
      AppTheme.dark(AppTheme.defaultSeed).colorScheme.onSurfaceVariant,
    );
  });
}
