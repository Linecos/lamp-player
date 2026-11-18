/// 音质分档：口径只在这里定义一次，音乐库统计、筛选和详情都从这里取。
///
/// 判据来自文件的原始标签（码率 / 采样率 / 位深），不落库：
/// 规则随时可能调，派生量重建一次列表就能重算。
library;

import 'package:lamp_player/src/rust/api/model.dart';

/// 四档评级，与环形图的四个扇区一一对应。
///
/// * [hiRes] —— 无损且（位深 ≥ 24 或采样率 > 48 kHz）
/// * [standard] —— 其余无损（16 bit / 44.1 kHz 这一档）
/// * [high] —— 有损但平均码率 ≥ 192 kbps
/// * [other] —— 低码率、未知或解析失败
enum AudioQuality { hiRes, standard, high, other }

/// Hi-Res 的位深门槛（bit）。
const int kHiResBitDepth = 24;

/// Hi-Res 的采样率门槛（Hz），超过才算，即 44.1 / 48 kHz 归 SQ。
const int kHiResSampleRate = 48000;

/// 有损 HQ 的码率门槛（kbps）；低于它算「其他」。
const int kHighQualityBitrate = 192;

/// 扩展名后备判据：标签里取不到位深时（解析不全），按容器格式兜底。
const Set<String> kLosslessExtensions = <String>{
  'flac',
  'ape',
  'wav',
  'aiff',
  'aif',
  'alac',
};

/// 直接从曲目派生评级。
AudioQuality audioQualityOf(Track track) => classifyAudioQuality(
  path: track.path,
  durationSecs: track.durationSecs,
  fileSize: track.fileSize,
  audioBitrate: track.audioBitrate,
  sampleRate: track.sampleRate,
  bitDepth: track.bitDepth,
);

/// 按原始标签值定级。
///
/// 未知值一律传 0（扫描时解析不到就写 0，与 Rust 侧一致）。
AudioQuality classifyAudioQuality({
  required String path,
  required double durationSecs,
  required int fileSize,
  required int audioBitrate,
  required int sampleRate,
  required int bitDepth,
}) {
  if (_isLossless(path, bitDepth)) {
    if (bitDepth >= kHiResBitDepth || sampleRate > kHiResSampleRate) {
      return AudioQuality.hiRes;
    }
    return AudioQuality.standard;
  }
  if (_kbpsOf(
        durationSecs: durationSecs,
        fileSize: fileSize,
        audioBitrate: audioBitrate,
      ) >=
      kHighQualityBitrate) {
    return AudioQuality.high;
  }
  return AudioQuality.other;
}

bool _isLossless(String path, int bitDepth) {
  // 有损编码（mp3 / aac / vorbis / opus）在 lofty 里位深恒为 0，
  // 所以「位深 > 0」本身就是最可靠的无损判据。
  if (bitDepth > 0) {
    return true;
  }
  final int dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) {
    return false;
  }
  return kLosslessExtensions.contains(path.substring(dot + 1).toLowerCase());
}

/// 平均码率（kbps）。标签没给时用「文件大小 + 时长」推算，
/// VBR 文件标称码率经常缺失，这一步能救回大半。
int _kbpsOf({
  required double durationSecs,
  required int fileSize,
  required int audioBitrate,
}) {
  if (audioBitrate > 0) {
    return audioBitrate;
  }
  if (fileSize <= 0 || durationSecs <= 0) {
    return 0;
  }
  return (fileSize * 8 / durationSecs / 1000).round();
}

/// 一次遍历得到的分布结果，环形图与统计文字共用。
class QualityBreakdown {
  QualityBreakdown._(this.counts, this.bytes);

  /// 按全部曲目统计。
  factory QualityBreakdown.of(Iterable<Track> tracks) {
    final Map<AudioQuality, int> counts = <AudioQuality, int>{
      for (final AudioQuality q in AudioQuality.values) q: 0,
    };
    final Map<AudioQuality, int> bytes = <AudioQuality, int>{
      for (final AudioQuality q in AudioQuality.values) q: 0,
    };
    for (final Track track in tracks) {
      final AudioQuality quality = audioQualityOf(track);
      counts[quality] = counts[quality]! + 1;
      bytes[quality] = bytes[quality]! + track.fileSize;
    }
    return QualityBreakdown._(counts, bytes);
  }

  /// 各档曲目数。
  final Map<AudioQuality, int> counts;

  /// 各档文件总字节数。
  final Map<AudioQuality, int> bytes;

  int get total => counts.values.fold(0, (int sum, int n) => sum + n);

  int get totalBytes => bytes.values.fold(0, (int sum, int n) => sum + n);

  int countOf(AudioQuality quality) => counts[quality] ?? 0;

  /// 占比（0~1）；空库返回 0，避免除零。
  double fractionOf(AudioQuality quality) {
    final int all = total;
    return all == 0 ? 0 : countOf(quality) / all;
  }
}
