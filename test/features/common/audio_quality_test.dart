import 'package:flutter_test/flutter_test.dart';
import 'package:lamp_player/src/common/audio/audio_quality.dart';
import 'package:lamp_player/src/rust/api/model.dart';

void main() {
  AudioQuality classify({
    String path = '/music/a.flac',
    double durationSecs = 180,
    int fileSize = 0,
    int audioBitrate = 0,
    int sampleRate = 0,
    int bitDepth = 0,
  }) => classifyAudioQuality(
    path: path,
    durationSecs: durationSecs,
    fileSize: fileSize,
    audioBitrate: audioBitrate,
    sampleRate: sampleRate,
    bitDepth: bitDepth,
  );

  group('无损', () {
    test('16 bit / 44.1 kHz 是 SQ', () {
      expect(
        classify(path: '/music/a.flac', bitDepth: 16, sampleRate: 44100),
        AudioQuality.standard,
      );
    });

    test('16 bit / 48 kHz 仍是 SQ（不超过 48 kHz）', () {
      expect(classify(bitDepth: 16, sampleRate: 48000), AudioQuality.standard);
    });

    test('24 bit / 44.1 kHz 算 HR', () {
      expect(classify(bitDepth: 24, sampleRate: 44100), AudioQuality.hiRes);
    });

    test('16 bit / 96 kHz 算 HR', () {
      expect(classify(bitDepth: 16, sampleRate: 96000), AudioQuality.hiRes);
    });

    test('位深缺失时按扩展名判无损', () {
      expect(
        classify(path: '/music/a.FLAC', sampleRate: 96000),
        AudioQuality.hiRes,
      );
      expect(
        classify(path: '/music/a.wav', sampleRate: 44100),
        AudioQuality.standard,
      );
    });
  });

  group('有损', () {
    test('320 kbps 是 HQ', () {
      expect(
        classify(path: '/music/a.mp3', audioBitrate: 320, sampleRate: 44100),
        AudioQuality.high,
      );
    });

    test('门槛边界：192 算 HQ，191 算其他', () {
      expect(
        classify(path: '/music/a.mp3', audioBitrate: 192),
        AudioQuality.high,
      );
      expect(
        classify(path: '/music/a.mp3', audioBitrate: 191),
        AudioQuality.other,
      );
    });

    test('低码率是其他', () {
      expect(
        classify(path: '/music/a.ogg', audioBitrate: 128),
        AudioQuality.other,
      );
    });

    test('码率缺失时用文件大小与时长推算', () {
      // 180 秒 / 7.2 MB ≈ 320 kbps
      expect(
        classify(path: '/music/a.mp3', durationSecs: 180, fileSize: 7200000),
        AudioQuality.high,
      );
      // 180 秒 / 2.1 MB ≈ 93 kbps
      expect(
        classify(path: '/music/a.mp3', durationSecs: 180, fileSize: 2100000),
        AudioQuality.other,
      );
    });

    test('完全未知归其他', () {
      expect(classify(path: '/music/a.mp3'), AudioQuality.other);
    });
  });

  group('QualityBreakdown', () {
    Track make({
      required String title,
      required int bitDepth,
      required int sampleRate,
      required int audioBitrate,
      required int fileSize,
      String path = '/music/x.flac',
    }) => Track(
      path: path,
      title: title,
      artist: null,
      album: null,
      durationSecs: 180,
      trackNum: null,
      addedAt: 0,
      coverPath: null,
      replayGain: 0,
      fileSize: fileSize,
      audioBitrate: audioBitrate,
      sampleRate: sampleRate,
      bitDepth: bitDepth,
      loudnessLufs: 0,
      samplePeak: 0,
      truePeak: 0,
    );

    test('按档统计曲目数与字节数', () {
      final QualityBreakdown breakdown = QualityBreakdown.of(<Track>[
        make(
          title: 'hr',
          bitDepth: 24,
          sampleRate: 96000,
          audioBitrate: 0,
          fileSize: 100,
        ),
        make(
          title: 'sq',
          bitDepth: 16,
          sampleRate: 44100,
          audioBitrate: 0,
          fileSize: 50,
        ),
        make(
          title: 'hq',
          path: '/music/x.mp3',
          bitDepth: 0,
          sampleRate: 44100,
          audioBitrate: 320,
          fileSize: 30,
        ),
        make(
          title: 'other',
          path: '/music/y.mp3',
          bitDepth: 0,
          sampleRate: 44100,
          audioBitrate: 96,
          fileSize: 10,
        ),
      ]);

      expect(breakdown.total, 4);
      expect(breakdown.totalBytes, 190);
      expect(breakdown.countOf(AudioQuality.hiRes), 1);
      expect(breakdown.countOf(AudioQuality.standard), 1);
      expect(breakdown.countOf(AudioQuality.high), 1);
      expect(breakdown.countOf(AudioQuality.other), 1);
      expect(breakdown.bytes[AudioQuality.hiRes], 100);
      expect(breakdown.fractionOf(AudioQuality.hiRes), 0.25);
    });

    test('空库不除零', () {
      final QualityBreakdown breakdown = QualityBreakdown.of(<Track>[]);
      expect(breakdown.total, 0);
      expect(breakdown.fractionOf(AudioQuality.hiRes), 0);
    });
  });
}
