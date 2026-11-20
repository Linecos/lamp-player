import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_version.dart';

/// 自动检查更新的频率。
///
/// 「每次启动」不做时间判断：由调用方保证一次启动只查一次。
enum UpdateCheckPeriod {
  everyLaunch('每次启动'),
  daily('每天'),
  weekly('每周'),
  monthly('每月');

  const UpdateCheckPeriod(this.label);

  /// 设置页下拉里显示的文案
  final String label;

  /// 存档里存的是枚举名；认不出来就回默认（每天）
  static UpdateCheckPeriod parse(String? name) {
    for (final UpdateCheckPeriod value in values) {
      if (value.name == name) {
        return value;
      }
    }
    return daily;
  }

  /// 距上次检查是否已经到点；从没查过就直接查。
  ///
  /// 按固定天数而不是自然日 / 自然月算：每天 24 小时、每周 7 天、每月 30 天。
  /// 这样时钟回拨或跨时区都不会出现「今天已经查过，改天又立刻查」的抖动。
  bool isDue(DateTime? lastCheckedAt, DateTime now) {
    if (lastCheckedAt == null) {
      return true;
    }
    final Duration elapsed = now.difference(lastCheckedAt);
    return switch (this) {
      everyLaunch => true,
      daily => elapsed >= const Duration(days: 1),
      weekly => elapsed >= const Duration(days: 7),
      monthly => elapsed >= const Duration(days: 30),
    };
  }
}

/// 一次「有新版本」的发布信息。
class UpdateRelease {
  const UpdateRelease({
    required this.version,
    required this.notes,
    required this.downloadUrl,
  });

  /// 去掉 `v` 前缀的版本号，例如 `0.2.0`
  final String version;

  /// 发布说明（Release body 原文，可能是 Markdown）
  final String notes;

  /// 下载页 / 安装包地址
  final String downloadUrl;
}

/// 检查更新的结果：三种情况互斥。
class UpdateCheckOutcome {
  const UpdateCheckOutcome({this.release, this.latestVersion, this.error});

  /// 有新版本时非空
  final UpdateRelease? release;

  /// 已是最新时带上当前版本号
  final String? latestVersion;

  /// 失败原因（网络 / 仓库没有发布）
  final String? error;

  bool get hasUpdate => release != null;

  bool get failed => error != null;
}

class UpdateCheckException implements Exception {
  const UpdateCheckException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 更新信息的数据源：GitHub 的 latest release。
const String updateReleasesApi =
    'https://api.github.com/repos/Linecos/lamp-player/releases/latest';

/// 抓取 JSON 文本；测试里换成假实现，避免跑用例时真发网络请求。
typedef JsonFetcher = Future<String> Function(Uri uri);

/// 比较两个版本号：返回负数表示 [a] 更旧，正数表示更新，0 相同。
///
/// 只比数字段：`v` 前缀、`+` 之后的构建号、`-beta` 这类后缀都不参与。
/// 段数不齐时缺的按 0 补（`0.1` 与 `0.1.0` 相等）。
int compareVersions(String a, String b) {
  final List<int> left = _numericParts(a);
  final List<int> right = _numericParts(b);
  final int length = left.length > right.length ? left.length : right.length;
  for (int i = 0; i < length; i += 1) {
    final int l = i < left.length ? left[i] : 0;
    final int r = i < right.length ? right[i] : 0;
    if (l != r) {
      return l < r ? -1 : 1;
    }
  }
  return 0;
}

bool isNewerVersion(String remote, String local) =>
    compareVersions(remote, local) > 0;

List<int> _numericParts(String version) {
  final String core = version
      .trim()
      .replaceAll(RegExp(r'^[vV]'), '')
      .split('+')
      .first
      .split('-')
      .first;
  final List<int> parts = <int>[];
  for (final String segment in core.split('.')) {
    final Match? digits = RegExp(r'\d+').firstMatch(segment);
    parts.add(digits == null ? 0 : int.parse(digits.group(0)!));
  }
  return parts;
}

/// 解析 GitHub `releases/latest` 的响应；结构不对返回 null。
///
/// 下载地址优先取安装包（`.exe` / `.zip` 资产），没有资产就退回发布页。
UpdateRelease? parseLatestRelease(String body) {
  final Object? decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic>) {
    return null;
  }
  final Object? tag = decoded['tag_name'];
  if (tag is! String || tag.trim().isEmpty) {
    return null;
  }

  String? assetUrl;
  final Object? assets = decoded['assets'];
  if (assets is List) {
    for (final Object? item in assets) {
      if (item is! Map) {
        continue;
      }
      final Object? name = item['name'];
      final Object? url = item['browser_download_url'];
      if (name is! String || url is! String) {
        continue;
      }
      final String lower = name.toLowerCase();
      if (lower.endsWith('.exe') || lower.endsWith('.zip')) {
        assetUrl = url;
        break;
      }
    }
  }

  final Object? htmlUrl = decoded['html_url'];
  final String downloadUrl =
      assetUrl ??
      (htmlUrl is String && htmlUrl.isNotEmpty
          ? htmlUrl
          : 'https://github.com/Linecos/lamp-player/releases');

  final Object? bodyText = decoded['body'];
  return UpdateRelease(
    version: tag.trim().replaceAll(RegExp(r'^[vV]'), ''),
    notes: bodyText is String ? bodyText : '',
    downloadUrl: downloadUrl,
  );
}

/// 真正发请求：GitHub 要求带 User-Agent，且超时要短（启动时不值得卡住界面）。
Future<String> _httpGetJson(Uri uri) async {
  final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 6);
  try {
    final HttpClientRequest request = await client.getUrl(uri);
    request.headers
      ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
      ..set(HttpHeaders.userAgentHeader, 'LampPlayer/$appVersion');
    final HttpClientResponse response = await request.close().timeout(
      const Duration(seconds: 8),
      onTimeout: () => throw const UpdateCheckException('连接超时'),
    );
    final String body = await response.transform(utf8.decoder).join();
    if (response.statusCode == 404) {
      throw const UpdateCheckException('仓库还没有发布任何版本');
    }
    if (response.statusCode != 200) {
      throw UpdateCheckException('服务返回 HTTP ${response.statusCode}');
    }
    return body;
  } on SocketException {
    throw const UpdateCheckException('网络不可用');
  } finally {
    client.close(force: true);
  }
}

/// 检查是否有新版本。永不抛异常：失败也包进 [UpdateCheckOutcome.error]。
Future<UpdateCheckOutcome> checkForUpdate({
  String apiUrl = updateReleasesApi,
  String currentVersion = appVersion,
  JsonFetcher fetcher = _httpGetJson,
}) async {
  try {
    final String body = await fetcher(Uri.parse(apiUrl));
    final UpdateRelease? release = parseLatestRelease(body);
    if (release == null) {
      return const UpdateCheckOutcome(error: '发布信息格式无法识别');
    }
    if (!isNewerVersion(release.version, currentVersion)) {
      return UpdateCheckOutcome(latestVersion: currentVersion);
    }
    return UpdateCheckOutcome(release: release);
  } on UpdateCheckException catch (error) {
    return UpdateCheckOutcome(error: error.message);
  } catch (_) {
    return const UpdateCheckOutcome(error: '网络不可用，稍后再试');
  }
}
