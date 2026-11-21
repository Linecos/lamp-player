import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show ByteData, FontLoader, rootBundle;

/// 随安装包分发的一款字体：一个文件就是一个可选的家族。
///
/// 字体文件不进版本库，由 `scripts/setup-misans.ps1` 从官方下载到
/// `assets/fonts/misans/`；没跑过脚本的机器上一个都注册不上，歌词字体选项里
/// 就不会出现 MiSans，其余功能一切照旧。
@immutable
class BundledFontFace {
  const BundledFontFace({
    required this.asset,
    required this.family,
    required this.label,
  });

  /// 资产路径（`pubspec.yaml` 里声明的是整个目录，缺文件不影响构建）
  final String asset;

  /// Flutter 侧 `TextStyle.fontFamily` 用的家族名。
  ///
  /// 直接用字体文件里的家族名 `MiSans`。早先随包发过四个字重时，四个文件同名，
  /// 注册到一起只剩一个可选值，才需要按字重各起别名；只发常规一款就没这个问题。
  /// 存档里残留的旧别名（`MiSans Light` 等）由 [normalizeLyricFontFamily] 归一。
  final String family;

  /// 下拉里显示的名字
  final String label;
}

/// MiSans 随包分发的字重。
///
/// 官方包有 10 个静态字重 + 1 个可变字体，全带会让安装包多出 80 MB。歌词只留
/// 常规一款：想换粗细，下拉里还有系统字体那几款（雅黑 Light / 黑体 / 宋体等），
/// 而每多带一个 MiSans 字重就是 8 MB 安装包。要再加字重就同步改
/// `scripts/setup-misans.ps1` 里的同一张表，再在这里加一行——其他代码都是遍历。
const List<BundledFontFace> kMiSansFaces = <BundledFontFace>[
  BundledFontFace(
    asset: 'assets/fonts/misans/MiSans-Regular.ttf',
    family: 'MiSans',
    label: 'MiSans',
  ),
];

/// 已注册成功的随包字体家族（测试里可以直接塞值，模拟「字体已下载」）
final Set<String> registeredBundledFamilies = <String>{};

/// 随包字体是否至少有一款可用（可选值与许可署名都看这个）
bool get misansAvailable => registeredBundledFamilies.isNotEmpty;

/// 这个家族名是不是随包 MiSans 的别名（`MiSans`、`MiSans Light`…）
///
/// GDI+ 那侧要把它归一成字体文件里的真实家族名。只认同名或以空格 / 连字符
/// 分隔的后缀，避免把 `MiSansx` 这类名字也吞掉。早先的四个字重别名仍按这个
/// 规则命中，存档老值才不会断掉。
bool isBundledMiSansFamily(String family) {
  final String name = family.trim().toLowerCase();
  return name == 'misans' ||
      name.startsWith('misans ') ||
      name.startsWith('misans-');
}

/// 注册随安装包分发的字体；在 `runApp` 之前调一次。
///
/// 为什么要运行时注册而不是写进 `pubspec` 的 `fonts:`：字体文件是被 gitignore
/// 的，写进 `fonts:` 会让「没下载字体」的机器（包括 CI）构建直接失败；运行时
/// 用 [FontLoader] 读资产，缺文件只是注册不上，程序照常跑。
Future<void> registerBundledFonts() async {
  registeredBundledFamilies.clear();
  for (final BundledFontFace face in kMiSansFaces) {
    try {
      final ByteData data = await rootBundle.load(face.asset);
      await (FontLoader(
        face.family,
      )..addFont(Future<ByteData>.value(data))).load();
      registeredBundledFamilies.add(face.family);
    } catch (error) {
      // 没跑过 setup-misans.ps1：正常情况，不打扰用户
      debugPrint('跳过打包字体 ${face.asset}：$error');
    }
  }
}
