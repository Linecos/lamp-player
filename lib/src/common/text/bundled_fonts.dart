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
  /// MiSans 各字重在字体文件里**共用同一个家族名 `MiSans`**，字重靠子族
  /// （Light / Regular / Medium / Bold）区分；要让用户能逐款选，注册时必须
  /// 各起一个别名，否则 Flutter 侧只有一个「MiSans」可选。
  final String family;

  /// 下拉里显示的名字
  final String label;
}

/// MiSans 随包分发的字重。
///
/// 官方包有 10 个静态字重 + 1 个可变字体，逐个全带会让安装包多出 80 MB；
/// 这里只取歌词实际用得上的四款（细 / 常规 / 中黑 / 粗）。想加减字重就改
/// `scripts/setup-misans.ps1` 里的同一张表，再在下面这行数组里对应增删即可，
/// 其他代码都是遍历，不用动。
const List<BundledFontFace> kMiSansFaces = <BundledFontFace>[
  BundledFontFace(
    asset: 'assets/fonts/misans/MiSans-Light.ttf',
    family: 'MiSans Light',
    label: 'MiSans 细体',
  ),
  BundledFontFace(
    asset: 'assets/fonts/misans/MiSans-Regular.ttf',
    family: 'MiSans Regular',
    label: 'MiSans 常规',
  ),
  BundledFontFace(
    asset: 'assets/fonts/misans/MiSans-Medium.ttf',
    family: 'MiSans Medium',
    label: 'MiSans 中黑',
  ),
  BundledFontFace(
    asset: 'assets/fonts/misans/MiSans-Bold.ttf',
    family: 'MiSans Bold',
    label: 'MiSans 粗体',
  ),
];

/// 已注册成功的随包字体家族（测试里可以直接塞值，模拟「字体已下载」）
final Set<String> registeredBundledFamilies = <String>{};

/// 随包字体是否至少有一款可用（可选值与许可署名都看这个）
bool get misansAvailable => registeredBundledFamilies.isNotEmpty;

/// 这个家族名是不是随包 MiSans 的别名（`MiSans`、`MiSans Light`…）
///
/// GDI+ 那侧要把它归一成字体文件里的真实家族名。只认同名或以空格 / 连字符
/// 分隔的后缀，避免把 `MiSansx` 这类名字也吞掉。
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
///
/// 每款字重单独注册成一个家族（见 [BundledFontFace.family]）：字体文件里它们
/// 同名，注册到一起就只剩一个可选值了。
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
