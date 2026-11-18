import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/audio/audio_quality.dart';
import 'package:lamp_player/src/features/library/widgets/quality_ring.dart';
import 'package:lamp_player/src/rust/api/model.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

import '../../support/fake_library.dart';

/// 环径跟着窗口变，中心读数如果写死字号，大环里显空、小环里顶到内圈。
void main() {
  double centerFontSize(WidgetTester tester) {
    final Text number = tester.widget<Text>(
      find
          .descendant(of: find.byType(QualityRing), matching: find.byType(Text))
          .first,
    );
    return number.style!.fontSize!;
  }

  Future<void> pumpRing(WidgetTester tester, double size) async {
    final QualityBreakdown breakdown = QualityBreakdown.of(<Track>[
      for (int i = 0; i < 5; i += 1)
        sampleTrack(title: '曲目$i', path: r'D:\Music\$i.mp3'),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(AppTheme.defaultSeed),
        home: Scaffold(
          body: Center(
            child: QualityRing(breakdown: breakdown, size: size),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('中心读数的字号跟着环径缩放', (WidgetTester tester) async {
    await pumpRing(tester, 120);
    final double small = centerFontSize(tester);
    await pumpRing(tester, 200);
    final double large = centerFontSize(tester);

    expect(large, greaterThan(small));
    // 20~34 的区间：小环不至于挤满内圈，大环也不会小得看不清
    expect(small, inInclusiveRange(20, 34));
    expect(large, inInclusiveRange(20, 34));
  });
}
