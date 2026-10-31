import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/features/player/player_bar.dart';
import 'package:lamp_player/src/features/settings/settings_view.dart';
import 'package:lamp_player/src/rust/api/model.dart';

import '../../support/fake_library.dart';
import '../../support/page_harness.dart';

void main() {
  testWidgets('设置页滚到底时「关于」停在播放岛上方', (WidgetTester tester) async {
    // 播放岛是浮层：设置列表的底部留白必须让出它的高度，否则最后一栏
    // 永远藏在岛后面，怎么滚都看不见
    await pumpLibrary(
      tester,
      tracks: <Track>[
        sampleTrack(title: 'A', artist: 'B', album: 'C', path: '/m/1.mp3'),
      ],
      viewSize: const Size(1080, 700),
    );
    await openSettings(tester);

    final Finder list = find.descendant(
      of: find.byType(SettingsView),
      matching: find.byType(ListView),
    );
    await tester.dragUntilVisible(find.text('关于'), list, const Offset(0, -260));
    await tester.pumpAndSettle();
    // 继续滚到底，确认没有「还能再滚一点」的余量被岛吃掉
    await tester.drag(list, const Offset(0, -2000));
    await tester.pumpAndSettle();

    final Rect about = tester.getRect(find.text('关于'));
    final Rect island = tester.getRect(find.byType(PlayerBar));
    expect(about.bottom, lessThanOrEqualTo(island.top));
  });
}
