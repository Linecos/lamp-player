import 'package:flutter/material.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

/// 全局主题：Material 3 + 可配置 seed 色与调色板风格，深浅色模式跟随系统。
///
/// seed 与调色板风格来自「外观 → 配色」：预设色板或系统强调色（动态取色）。
/// 不要在页面里写死颜色，一律用 `Theme.of(context).colorScheme.*`。
abstract final class AppTheme {
  /// 默认主色种子：台灯灯光的暖黄；也是「未选自定义色且读不到
  /// 系统强调色」时的兜底。
  static const Color defaultSeed = Color(0xFFFFB300);

  /// 默认调色板风格：Material 3 的 Tonal spot（与历史版本行为一致）。
  static const DynamicSchemeVariant defaultVariant =
      DynamicSchemeVariant.tonalSpot;

  /// 「强调色跟随封面」时强制使用的调色板风格。
  ///
  /// Tonal spot 会把颜色洗淡（实测薄荷 `S86 → 48`、封面绿 `S60 → 45`），
  /// 跟封面联动就会「颜色明明很艳、界面却灰扑扑」。Fidelity / Content 保留源色的
  /// 色相与彩度，遇到灰封面又老实变中性，正是这里要的行为。
  ///
  /// 注意 fidelity 的另一面：**它连源色的亮度也一起保留**，所以特别亮的种子
  /// （tone 90 的亮黄）会生成纯白的 primary。取色一侧把种子压到 tone 78 以内
  /// （见 `CoverPaletteCache`），这里只负责定风格。
  static const DynamicSchemeVariant coverVariant =
      DynamicSchemeVariant.fidelity;

  /// 预设强调色板：设置页可一键选用，都是 MD3 seed 友好的饱和色。
  static const List<Color> presetSeeds = <Color>[
    Color(0xFFFFB300), // 台灯暖黄（默认）
    Color(0xFFE91E63), // 玫红
    Color(0xFFF44336), // 朱红
    Color(0xFFFF9800), // 橙
    Color(0xFF4CAF50), // 绿
    Color(0xFF009688), // 青绿
    Color(0xFF00BCD4), // 青
    Color(0xFF2196F3), // 蓝
    Color(0xFF3F51B5), // 靛蓝
    Color(0xFF9C27B0), // 紫
  ];

  /// 调色板风格中文名，顺序与 [DynamicSchemeVariant.values] 对应之外单独列出，
  /// 便于设置页展示与测试断言。
  static const List<(DynamicSchemeVariant, String)> variantOptions =
      <(DynamicSchemeVariant, String)>[
        (DynamicSchemeVariant.tonalSpot, 'Tonal spot'),
        (DynamicSchemeVariant.fidelity, 'Fidelity'),
        (DynamicSchemeVariant.content, 'Content'),
        (DynamicSchemeVariant.vibrant, 'Vibrant'),
        (DynamicSchemeVariant.expressive, 'Expressive'),
        (DynamicSchemeVariant.rainbow, 'Rainbow'),
        (DynamicSchemeVariant.fruitSalad, 'Fruit salad'),
        (DynamicSchemeVariant.neutral, 'Neutral'),
        (DynamicSchemeVariant.monochrome, 'Monochrome'),
      ];

  /// 由 seed + 风格 + 对比度生成 ColorScheme；色卡预览与主题共用这一个入口，
  /// 保证「所见即所得」。
  static ColorScheme schemeOf(
    Color seed,
    Brightness brightness,
    DynamicSchemeVariant variant, {
    double contrastLevel = 0,
  }) {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      dynamicSchemeVariant: variant,
      contrastLevel: contrastLevel,
    );
    // 高对比档位是给「看不清」的人用的，白底本身就是对比度上限，不覆盖
    if (brightness == Brightness.light && contrastLevel == 0) {
      return _tintLightSurfaces(scheme, seed);
    }
    return scheme;
  }

  /// 给浅色底「上色」。
  ///
  /// Material 生成的浅色 surface 系列几乎全是白的：`surfaceContainerLowest`
  /// 直接就是 `#FFFFFF`，`low` / `container` / `high` / `highest` 之间也只差
  /// 2 个 tone，岛式分块布局铺开就是一张白纸，看不出底和封面 / 强调色有任何
  /// 关系；深色那边 tone 本来就压在 4~22，同样的 chroma 一眼就能看出色调。
  ///
  /// 这里按 seed 的色相把浅色底重铺一遍：整体比原值低 2~4 个 tone（离开纯白，
  /// 越低的那几档压得越多），相邻层距从 2 拉到 2~3（卡片和缝才分得开），
  /// chroma 提到 10（原值 2~7，在 tone 90 以上基本看不见）。只动 surface 系列，
  /// `on*` 原样保留，前景对比度只会更高。
  static ColorScheme _tintLightSurfaces(ColorScheme scheme, Color seed) {
    final Hct base = Hct.fromInt(seed.toARGB32());
    // 中性 seed（灰 / 白 / 黑）没有可用的色相，硬塞会凭空多出一层红或紫
    final double chroma = base.chroma < 4 ? base.chroma : 10;
    Color tone(double value) =>
        Color(Hct.from(base.hue, chroma, value).toInt());
    return scheme.copyWith(
      surface: tone(97),
      surfaceDim: tone(88),
      // 不用 99：tone 这么高时 sRGB 装不下这个 chroma，会映射成一个偏紫的白
      surfaceBright: tone(98),
      surfaceContainerLowest: tone(96),
      surfaceContainerLow: tone(94),
      surfaceContainer: tone(92),
      surfaceContainerHigh: tone(89),
      surfaceContainerHighest: tone(86),
    );
  }

  /// 默认字体：微软雅黑 Light。
  ///
  /// 比系统默认的 Segoe UI 更适合中文界面：汉字不再走随机回退（宋体/等线），
  /// 笔画也更轻、正文密度更均匀。拉丁字母同样由它自带的字形渲染。
  static const String fontFamily = 'Microsoft YaHei Light';

  /// 回退链：某些机器没装 Light 字型，或用到了它没有的符号时兜底。
  static const List<String> fontFallback = <String>[
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'Segoe UI',
    'Noto Sans CJK SC',
    'Noto Sans SC',
    'Source Han Sans SC',
    'PingFang SC',
    'sans-serif',
  ];

  static ThemeData light(
    Color seed, {
    DynamicSchemeVariant variant = defaultVariant,
    double contrastLevel = 0,
  }) => _build(Brightness.light, seed, variant, contrastLevel);

  static ThemeData dark(
    Color seed, {
    DynamicSchemeVariant variant = defaultVariant,
    double contrastLevel = 0,
  }) => _build(Brightness.dark, seed, variant, contrastLevel);

  static ThemeData _build(
    Brightness brightness,
    Color seed,
    DynamicSchemeVariant variant,
    double contrastLevel,
  ) {
    final ColorScheme scheme = schemeOf(
      seed,
      brightness,
      variant,
      contrastLevel: contrastLevel,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFallback,
      appBarTheme: const AppBarTheme(centerTitle: false),
      visualDensity: VisualDensity.adaptivePlatformDensity,
      // Flutter 默认 `Clip.none`：弹窗里的子节点（ListTile 的选中背景、水波纹
      // 都是画在 Material 上的墨迹）可以画到 28px 圆角外面，露出直角方块。
      // 统一裁到弹窗形状，避免任何墨迹越界。
      dialogTheme: const DialogThemeData(clipBehavior: Clip.antiAlias),
    );
  }
}
