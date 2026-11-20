import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/lamp_icons.dart';

/// 从 TTF 的 `cmap` 表里读出所有码位。
///
/// 只解析 format 4（BMP，本项目码位都在 U+E000 私有区）与 format 12（完整
/// Unicode），够用且不引依赖。
Set<int> _codePointsOf(Uint8List font) {
  final ByteData data = ByteData.sublistView(font);
  final int numTables = data.getUint16(4);
  int cmapOffset = -1;
  for (int i = 0; i < numTables; i += 1) {
    final int record = 12 + i * 16;
    final String tag = String.fromCharCodes(<int>[
      data.getUint8(record),
      data.getUint8(record + 1),
      data.getUint8(record + 2),
      data.getUint8(record + 3),
    ]);
    if (tag == 'cmap') {
      cmapOffset = data.getUint32(record + 8);
      break;
    }
  }
  if (cmapOffset < 0) {
    throw StateError('字体里没有 cmap 表');
  }

  final Set<int> result = <int>{};
  final int subTables = data.getUint16(cmapOffset + 2);
  for (int i = 0; i < subTables; i += 1) {
    final int record = cmapOffset + 4 + i * 8;
    final int sub = cmapOffset + data.getUint32(record + 4);
    final int format = data.getUint16(sub);

    if (format == 4) {
      final int segCount = data.getUint16(sub + 6) ~/ 2;
      final int endBase = sub + 14;
      final int startBase = endBase + segCount * 2 + 2;
      for (int seg = 0; seg < segCount; seg += 1) {
        final int end = data.getUint16(endBase + seg * 2);
        final int start = data.getUint16(startBase + seg * 2);
        if (start == 0xffff && end == 0xffff) {
          continue;
        }
        for (int code = start; code <= end; code += 1) {
          result.add(code);
        }
      }
    } else if (format == 12) {
      final int groups = data.getUint32(sub + 12);
      for (int g = 0; g < groups; g += 1) {
        final int group = sub + 16 + g * 12;
        final int start = data.getUint32(group);
        final int end = data.getUint32(group + 4);
        for (int code = start; code <= end; code += 1) {
          result.add(code);
        }
      }
    }
  }
  return result;
}

void main() {
  test('自带图标字体的字形与 pubspec 都齐', () {
    final File font = File('assets/fonts/lamp_icons.ttf');
    expect(font.existsSync(), isTrue, reason: '字体文件不存在');
    final Uint8List bytes = font.readAsBytesSync();
    expect(bytes.length, greaterThan(1024), reason: '字体文件过小，可能是占位文件');

    final String pubspec = File('pubspec.yaml').readAsStringSync();
    expect(
      pubspec.contains('family: LampIcons'),
      isTrue,
      reason: 'pubspec.yaml 必须声明 LampIcons 字体族',
    );
    expect(
      pubspec.contains('assets/fonts/lamp_icons.ttf'),
      isTrue,
      reason: 'pubspec.yaml 里的字体路径要和生成的产物一致',
    );

    // 断言的是「字形真的在字体里」：改 SVG 后忘了重跑生成命令，这里会红。
    // （`IconData` 里的码位在字体里没有对应字形时，Flutter 画出来是空方框）
    final Set<int> codePoints = _codePointsOf(bytes);
    for (final IconData icon in <IconData>[
      LampIcons.albumFilled,
      LampIcons.albumOutlined,
      LampIcons.barChart4Bars,
      LampIcons.brushVariant,
      LampIcons.storeFilled,
      LampIcons.storeOutline,
    ]) {
      expect(
        codePoints.contains(icon.codePoint),
        isTrue,
        reason: '字体里没有 U+${icon.codePoint.toRadixString(16)} 的字形',
      );
      expect(
        icon.fontFamily,
        LampIcons.iconFontFamily,
        reason: '字形必须挂在 LampIcons 字体族上',
      );
    }
  });

  test('侧栏图标：选中实心、未选中空心', () {
    // 两态用不同字形而不是同一个字形换颜色，点下去才看得出切换
    expect(
      LampIcons.albumOutlined.codePoint,
      isNot(LampIcons.albumFilled.codePoint),
    );
    expect(
      LampIcons.storeOutline.codePoint,
      isNot(LampIcons.storeFilled.codePoint),
    );
  });
}
