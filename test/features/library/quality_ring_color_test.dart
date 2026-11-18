import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/audio/audio_quality.dart';
import 'package:lamp_player/src/features/library/widgets/quality_ring.dart';
import 'package:lamp_player/src/theme/app_theme.dart';

/// 四档配色是「看得见的数据」：WCAG 1.4.11 要求图形元素与相邻底色
/// 至少 3:1，否则浅色主题下最淡的那一档会消失在卡片里。
void main() {
  const List<Brightness> brightnesses = <Brightness>[
    Brightness.light,
    Brightness.dark,
  ];

  test('全部预设 seed × 深浅色下，四档对卡片底色都 ≥ 3:1', () {
    for (final Color seed in AppTheme.presetSeeds) {
      for (final Brightness brightness in brightnesses) {
        final ColorScheme scheme = AppTheme.schemeOf(
          seed,
          brightness,
          AppTheme.defaultVariant,
        );
        for (final AudioQuality quality in AudioQuality.values) {
          final double contrast = contrastRatio(
            sliceColor(scheme, quality),
            scheme.surfaceContainerHigh,
          );
          expect(
            contrast,
            greaterThanOrEqualTo(3.0),
            reason:
                'seed ${seed.toARGB32().toRadixString(16)} / '
                '${brightness.name} / ${quality.name} = '
                '${contrast.toStringAsFixed(2)}:1',
          );
        }
      }
    }
  });

  test('高对比档位同样成立', () {
    for (final Brightness brightness in brightnesses) {
      final ColorScheme scheme = AppTheme.schemeOf(
        AppTheme.defaultSeed,
        brightness,
        AppTheme.defaultVariant,
        contrastLevel: 1,
      );
      for (final AudioQuality quality in AudioQuality.values) {
        expect(
          contrastRatio(
            sliceColor(scheme, quality),
            scheme.surfaceContainerHigh,
          ),
          greaterThanOrEqualTo(3.0),
          reason: '${brightness.name} / ${quality.name}',
        );
      }
    }
  });

  test('四档依然是逐级变淡的阶梯', () {
    for (final Color seed in AppTheme.presetSeeds) {
      for (final Brightness brightness in brightnesses) {
        final ColorScheme scheme = AppTheme.schemeOf(
          seed,
          brightness,
          AppTheme.defaultVariant,
        );
        double contrastOf(AudioQuality quality) => contrastRatio(
          sliceColor(scheme, quality),
          scheme.surfaceContainerHigh,
        );
        // 四档必须各是各的颜色：原色 4.9:1 时如果硬套 5.2 的目标，
        // SQ 会退化成和 HR 一样的原色，阶梯就少了一级
        expect(
          contrastOf(AudioQuality.hiRes),
          greaterThan(contrastOf(AudioQuality.standard)),
          reason:
              'seed ${seed.toARGB32().toRadixString(16)} / ${brightness.name}',
        );
        expect(
          contrastOf(AudioQuality.standard),
          greaterThan(contrastOf(AudioQuality.high)),
        );
        expect(
          contrastOf(AudioQuality.high),
          greaterThan(contrastOf(AudioQuality.other)),
        );
      }
    }
  });
}
