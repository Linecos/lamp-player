import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/player/cover_palette.dart';
import 'package:lamp_player/src/features/settings/theme_controller.dart';
import 'package:lamp_player/src/rust/api/model.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_library.dart';
import '../../support/page_harness.dart';

/// 120×120 的测试封面：大面积底色 + 右下角 38×38 的一块强调色。
///
/// 用内嵌 PNG 而不是画布现画：`toImage` 在 testWidgets 里要真实异步、容易卡住，
/// 而且图片内容固定才能断言「选中了哪一块颜色」。
const String _navyPinkPng =
    'iVBORw0KGgoAAAANSUhEUgAAAHgAAAB4CAIAAAC2BqGFAAAAx0lEQVR42u3U'
    'MQ0AIAxFQSBYYEEAcmodO4x4IOnEPQe9/LTOFUX5NQSgQQs0aNACDVqgQYMW'
    'aNACDRq0QIMWaNCgBRq0QIMGLdCgBRo0aIEGLdCgQQs0aIEGDVqgQQs0aNAC'
    'DVqgQYMWaNACDRq0QIMWaNCgBRq0QIMGLdCgBRo0aIEGLdCgQQs0aIEGDVo5'
    '9T/P3mdYtNch0KAFGjRogQYt0KBBCzRogQYNWqBBCzRo0AINWqBBgxZo0AIN'
    'GrRAgxZo0KD10gUo1gNcH2Z+5gAAAABJRU5ErkJggg==';

const String _grayPng =
    'iVBORw0KGgoAAAANSUhEUgAAAHgAAAB4CAIAAAC2BqGFAAAAwklEQVR42u3U'
    'wQkAIAwEQRX7u07S/9MeAnk520GGI7uqluY7CECDFmjQoAUatECDBi3QoAUa'
    'NGiBBi3QoEELNGiBBg1aoEELNGjQAg1aoEGDFmjQAg0atECDFmjQoAUatECD'
    'Bi3QoAUaNGiBBi3QoEELNGiBBg1aoEELNGjQAg1aoEGDFmjQAg0atGa6f56d'
    'xKK9DoEGLdCgQQs0aIEGDVqgQQs0aNACDVqgQYMWaNACDRq0QIMWaNCgBRq0'
    'QIMGrU4PUNsDKZs5WbUAAAAASUVORK5CYII=';

void main() {
  late Directory dir;

  setUp(() {
    // 主题设置要往 SharedPreferences 写；不给 mock 的话平台通道永远等不到回复，
    // 整个用例会挂在那里
    SharedPreferences.setMockInitialValues(<String, Object>{});
    dir = Directory.systemTemp.createTempSync('lamp-cover-theme');
  });

  tearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  String writeCover(String name, String base64) {
    final File file = File('${dir.path}/$name.png');
    file.writeAsBytesSync(base64Decode(base64));
    return file.path;
  }

  /// 预热取色缓存：文件解码是真实异步，必须放在 runAsync 里
  Future<void> warmUp(WidgetTester tester, List<String> paths) async {
    await tester.runAsync(() async {
      for (final String path in paths) {
        await CoverPaletteCache.loadSeed(path);
      }
    });
  }

  testWidgets('开启跟随后，播放一首带封面的歌会把主题色换成封面色', (WidgetTester tester) async {
    const Color pink = Color(0xFFE91E63);
    final String coverPath = writeCover('navy_pink', _navyPinkPng);
    await warmUp(tester, <String>[coverPath]);

    final ThemeController controller = ThemeController();
    await controller.setFollowCover(true);
    addTearDown(controller.dispose);

    await pumpLibrary(
      tester,
      tracks: <Track>[
        sampleTrack(title: '夜航', album: '夜之专辑', coverPath: coverPath),
        sampleTrack(title: '潮汐', album: '玻璃海', durationSecs: 200),
      ],
      playback: FakePlaybackService(isAvailable: true, durationSecs: 180),
      themeController: controller,
    );

    expect(controller.coverSeed, isNull, reason: '还没播歌，没有封面色');

    await tester.tap(find.text('夜航'));
    await tester.pump();
    // 取色命中缓存，只等微任务落地
    await tester.pump();

    final Color? seed = controller.coverSeed;
    expect(seed, isNotNull, reason: '播放之后应该取到封面色');
    final HSLColor picked = HSLColor.fromColor(seed!);
    final HSLColor expected = HSLColor.fromColor(pink);
    expect(
      (picked.hue - expected.hue).abs(),
      lessThan(30),
      reason: '主题色应该跟着封面里那块鲜艳的品红，而不是深藏青',
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('没开启跟随时不取色，主题保持用户选的颜色', (WidgetTester tester) async {
    final String coverPath = writeCover('navy_pink', _navyPinkPng);
    await warmUp(tester, <String>[coverPath]);

    const Color custom = Color(0xFF009688);
    final ThemeController controller = ThemeController();
    await controller.setSeedColor(custom);
    addTearDown(controller.dispose);

    await pumpLibrary(
      tester,
      tracks: <Track>[
        sampleTrack(title: '夜航', album: '夜之专辑', coverPath: coverPath),
        sampleTrack(title: '潮汐', album: '玻璃海', durationSecs: 200),
      ],
      playback: FakePlaybackService(isAvailable: true, durationSecs: 180),
      themeController: controller,
    );

    await tester.tap(find.text('夜航'));
    await tester.pump();
    await tester.pump();

    expect(controller.coverSeed, isNull, reason: '没开启就一次色都不该取');
    expect(controller.effectiveSeed, custom);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('灰封面不换色：保留上一首的颜色', (WidgetTester tester) async {
    final String vivid = writeCover('vivid', _navyPinkPng);
    final String gray = writeCover('gray', _grayPng);
    await warmUp(tester, <String>[vivid, gray]);

    final ThemeController controller = ThemeController();
    await controller.setFollowCover(true);
    addTearDown(controller.dispose);

    await pumpLibrary(
      tester,
      tracks: <Track>[
        sampleTrack(title: '夜航', album: '夜之专辑', coverPath: vivid),
        sampleTrack(
          title: '潮汐',
          album: '玻璃海',
          coverPath: gray,
          durationSecs: 200,
        ),
      ],
      playback: FakePlaybackService(isAvailable: true, durationSecs: 180),
      themeController: controller,
    );

    await tester.tap(find.text('夜航'));
    await tester.pump();
    await tester.pump();
    final Color? first = controller.coverSeed;
    expect(first, isNotNull);

    // 切到灰封面那首：没有合格候选，颜色应该原地不动
    await tester.tap(find.text('潮汐'));
    await tester.pump();
    await tester.pump();

    expect(controller.coverSeed, first, reason: '灰封面不该把主题色改掉');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
