/// 圆角与间距档位。
///
/// 之前这些数字直接散在代码里（圆角 15 种、间距还混着 6/10/14 的第二套节奏），
/// 改起来全靠「看着顺眼」。这里把已经存在的层级固化成档位，新代码一律用常量：
///
/// 圆角：播放岛 / 大卡 32 > 弹窗 / 设置行卡 24 > 卡片与岛 16 > 菜单 / 输入 / 小卡 12
///       > 小件 8 > 胶囊与细条（被 RRect 夹到半高，等于全圆）999
/// 间距：4 / 8 / 12 / 16 / 24 / 32，主节奏 4 的倍数
library;

/// 圆角档位
///
/// 数字是 M3 Expressive 的观感：整体比原版圆两档（弹窗 32、卡片 24、播放岛 40），
/// 细条与胶囊照旧夹到半高。
abstract final class Radii {
  /// 小件：徽标、细条里的装饰块、输入框描边
  static const double xs = 16;

  /// 菜单、输入框、列表项里的小卡
  static const double sm = 20;

  /// 卡片与侧栏「岛」
  static const double md = 24;

  /// 弹窗、设置页的行卡
  static const double lg = 32;

  /// 播放岛、大卡片
  static const double xl = 40;

  /// 胶囊与细条：RRect 会把半径夹到短边一半，所以对细条等于「全圆」
  static const double pill = 999;
}

/// 间距档位：一律 4 的倍数，不再出现 6 / 10 / 14 这类“看着顺眼”的第二套节奏
abstract final class Spacing {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
}
