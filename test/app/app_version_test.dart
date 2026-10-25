import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/app/app_version.dart';

void main() {
  test('界面版本号与 pubspec.yaml 一致', () {
    final List<String> lines = File('pubspec.yaml').readAsLinesSync();
    final String versionLine = lines.firstWhere(
      (String line) => line.startsWith('version:'),
      orElse: () => '',
    );
    expect(versionLine, isNotEmpty, reason: 'pubspec.yaml 应包含 version 字段');

    // `version: 0.1.0+1` → 0.1.0
    final String raw = versionLine.substring('version:'.length).trim();
    final String pubspecVersion = raw.split('+').first;
    expect(
      appVersion,
      pubspecVersion,
      reason: 'lib/src/app/app_version.dart 与 pubspec.yaml 的版本号要一起改',
    );
  });
}
