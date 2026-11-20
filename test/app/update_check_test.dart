import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/app/update_check.dart';

const String _payload = '''
{
  "tag_name": "v0.2.0",
  "body": "### 修复\\n- 修某处",
  "html_url": "https://github.com/Linecos/lamp-player/releases/tag/v0.2.0",
  "assets": [
    {"name": "lamp_player-0.2.0-windows.tar.gz", "browser_download_url": "https://example.com/a.tar.gz"},
    {"name": "lamp_player-0.2.0-windows.zip", "browser_download_url": "https://example.com/a.zip"}
  ]
}
''';

void main() {
  group('版本比较', () {
    test('按数字段逐段比较，不是字符串比较', () {
      expect(compareVersions('0.2.0', '0.1.0'), greaterThan(0));
      expect(compareVersions('0.1.10', '0.1.9'), greaterThan(0));
      expect(compareVersions('0.1.0', '0.1.0'), 0);
    });

    test('v 前缀、构建号与段数不齐都不影响结果', () {
      expect(compareVersions('v0.2.0', '0.1.99'), greaterThan(0));
      expect(compareVersions('0.1.0+3', '0.1.0'), 0);
      expect(compareVersions('0.1', '0.1.0'), 0);
      expect(compareVersions('0.1.0-beta.2', '0.1.0'), 0, reason: '后缀不参与比较');
    });

    test('isNewerVersion 只在远端更新时成立', () {
      expect(isNewerVersion('0.2.0', '0.1.0'), isTrue);
      expect(isNewerVersion('0.1.0', '0.1.0'), isFalse);
      expect(isNewerVersion('0.0.9', '0.1.0'), isFalse);
    });
  });

  group('发布信息解析', () {
    test('取 tag、说明与安装包资产', () {
      final UpdateRelease? release = parseLatestRelease(_payload);
      expect(release, isNotNull);
      expect(release!.version, '0.2.0');
      expect(release.notes, contains('修某处'));
      expect(
        release.downloadUrl,
        'https://example.com/a.zip',
        reason: '优先安装包，不是源码包',
      );
    });

    test('没有资产时退回发布页', () {
      final UpdateRelease? release = parseLatestRelease(
        jsonEncode(<String, Object>{
          'tag_name': 'v3.0.0',
          'html_url':
              'https://github.com/Linecos/lamp-player/releases/tag/v3.0.0',
          'body': '',
        }),
      );
      expect(release!.downloadUrl, contains('/releases/tag/v3.0.0'));
      expect(release.notes, isEmpty);
    });

    test('缺 tag 或不是对象时返回 null', () {
      expect(parseLatestRelease('{}'), isNull);
      expect(parseLatestRelease('[]'), isNull);
      expect(
        () => parseLatestRelease('not json'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('自动检查频率', () {
    final DateTime now = DateTime(2026, 11, 20, 9);

    test('从没查过时任何频率都该查', () {
      for (final UpdateCheckPeriod period in UpdateCheckPeriod.values) {
        expect(period.isDue(null, now), isTrue, reason: period.label);
      }
    });

    test('每次启动永远到点', () {
      expect(UpdateCheckPeriod.everyLaunch.isDue(now, now), isTrue);
    });

    test('每天 / 每周 / 每月按固定天数判断', () {
      expect(
        UpdateCheckPeriod.daily.isDue(
          now.subtract(const Duration(hours: 23)),
          now,
        ),
        isFalse,
      );
      expect(
        UpdateCheckPeriod.daily.isDue(
          now.subtract(const Duration(hours: 25)),
          now,
        ),
        isTrue,
      );
      expect(
        UpdateCheckPeriod.weekly.isDue(
          now.subtract(const Duration(days: 6)),
          now,
        ),
        isFalse,
      );
      expect(
        UpdateCheckPeriod.weekly.isDue(
          now.subtract(const Duration(days: 8)),
          now,
        ),
        isTrue,
      );
      expect(
        UpdateCheckPeriod.monthly.isDue(
          now.subtract(const Duration(days: 29)),
          now,
        ),
        isFalse,
      );
      expect(
        UpdateCheckPeriod.monthly.isDue(
          now.subtract(const Duration(days: 31)),
          now,
        ),
        isTrue,
      );
    });

    test('档位名认不出来时回落到每天', () {
      expect(UpdateCheckPeriod.parse('weekly'), UpdateCheckPeriod.weekly);
      expect(UpdateCheckPeriod.parse('nope'), UpdateCheckPeriod.daily);
      expect(UpdateCheckPeriod.parse(null), UpdateCheckPeriod.daily);
    });
  });

  group('checkForUpdate', () {
    test('远端更新时带上发布信息', () async {
      final UpdateCheckOutcome outcome = await checkForUpdate(
        currentVersion: '0.1.0',
        fetcher: (Uri uri) async => _payload,
      );
      expect(outcome.hasUpdate, isTrue);
      expect(outcome.release!.version, '0.2.0');
    });

    test('一样新时返回当前版本，不弹更新', () async {
      final UpdateCheckOutcome outcome = await checkForUpdate(
        currentVersion: '0.2.0',
        fetcher: (Uri uri) async => _payload,
      );
      expect(outcome.hasUpdate, isFalse);
      expect(outcome.failed, isFalse);
      expect(outcome.latestVersion, '0.2.0');
    });

    test('网络异常包成失败，不抛给调用方', () async {
      final UpdateCheckOutcome outcome = await checkForUpdate(
        fetcher: (Uri uri) async => throw const UpdateCheckException('网络不可用'),
      );
      expect(outcome.failed, isTrue);
      expect(outcome.error, '网络不可用');
    });

    test('响应格式不对算失败', () async {
      final UpdateCheckOutcome outcome = await checkForUpdate(
        fetcher: (Uri uri) async => '{}',
      );
      expect(outcome.failed, isTrue);
      expect(outcome.error, contains('格式'));
    });
  });

  group('代理环境变量', () {
    // _httpGetJson 挂的是 HttpClient.findProxyFromEnvironment：这里直接
    // 测这套机制对环境变量的反应，保证「设了代理就别直连」这个前提成立。
    final Uri github = Uri.parse(
      'https://api.github.com/repos/Linecos/lamp-player/releases/latest',
    );

    test('https_proxy 指到本机代理时请求走 PROXY', () {
      final String strategy = HttpClient.findProxyFromEnvironment(
        github,
        environment: <String, String>{'https_proxy': '127.0.0.1:7890'},
      );
      expect(strategy, contains('PROXY 127.0.0.1:7890'));
    });

    test('大写 HTTPS_PROXY 也认', () {
      final String strategy = HttpClient.findProxyFromEnvironment(
        github,
        environment: <String, String>{'HTTPS_PROXY': '127.0.0.1:7890'},
      );
      expect(strategy, contains('PROXY 127.0.0.1:7890'));
    });

    test('没设任何变量时是 DIRECT，行为与以前一致', () {
      final String strategy = HttpClient.findProxyFromEnvironment(
        github,
        environment: const <String, String>{},
      );
      expect(strategy, contains('DIRECT'));
      expect(strategy, isNot(contains('PROXY')));
    });

    test('no_proxy 覆盖的地址直连', () {
      final String strategy = HttpClient.findProxyFromEnvironment(
        github,
        environment: <String, String>{
          'https_proxy': '127.0.0.1:7890',
          'no_proxy': 'api.github.com',
        },
      );
      expect(strategy, isNot(contains('PROXY 127.0.0.1:7890')));
    });
  });
}
