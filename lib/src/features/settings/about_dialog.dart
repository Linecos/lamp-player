import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_version.dart';
import '../../common/external_link.dart';
import '../../common/lamp_icons.dart';
import '../../common/scroll/smooth_scroll.dart';

/// 「关于」弹窗：大图标 → 名字 → 版本行 → 标语 → 技术栈 → 2×2 链接 → 署名。
///
/// 所有链接都走 [OpenExternalUrl]，默认是 [openExternalUrl]（系统浏览器）；
/// 测试里换成假实现，免得跑用例时真去拉浏览器。
Future<void> showAppAboutDialog(
  BuildContext context, {
  OpenExternalUrl? openUrl,
}) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) =>
        AppAboutDialog(openUrl: openUrl ?? openExternalUrl),
  );
}

/// 技术栈的展示色：各自取品牌色，深浅主题下再按对比度压一压
enum _Tech {
  flutter('Flutter', LampIcons.flutter, Color(0xFF54C5F8)),
  rust('Rust', Icons.code, Color(0xFFD97757)),
  bass('BASS', Icons.graphic_eq, Color(0xFFFFB300));

  const _Tech(this.label, this.icon, this.brand);

  final String label;
  final IconData icon;
  final Color brand;
}

class AppAboutDialog extends StatefulWidget {
  const AppAboutDialog({super.key, required this.openUrl});

  final OpenExternalUrl openUrl;

  static const String githubUrl = 'https://github.com/Linecos/lamp-player';
  static const String changelogUrl =
      'https://github.com/Linecos/lamp-player/blob/main/CHANGELOG.md';
  static const String licenseUrl =
      'https://github.com/Linecos/lamp-player/blob/main/LICENSE';
  static const String issuesUrl =
      'https://github.com/Linecos/lamp-player/issues';
  static const String authorUrl = 'https://github.com/Linecos';

  /// 三个技术栈（弹窗里横排展示）
  static const List<String> techStack = <String>['Flutter', 'Rust', 'BASS'];

  /// 设计基准：弹窗按 440 宽排版，窗口不小于 [designViewport] 时就是 1.0。
  ///
  /// 全屏（1920×1080 / 1470×1000）下原尺寸正好，窗口一缩小弹窗不跟着缩，
  /// 440×约 620 的卡片会几乎顶满窗口、「看着很大」。
  static const double designWidth = 440;
  static const Size designViewport = Size(1200, 820);

  /// 缩到 0.75 就不再缩了：再小字和点击区都要看不清 / 点不中，
  /// 剩下的高度交给内容自己的滚动。
  static const double minScale = 0.75;

  /// 弹窗相对窗口的缩放比例：取宽高两条比例里小的那条，再夹进 [minScale, 1]。
  static double scaleFor(Size viewport) {
    final double byWidth = viewport.width / designViewport.width;
    final double byHeight = viewport.height / designViewport.height;
    return math.min(byWidth, byHeight).clamp(minScale, 1.0);
  }

  @override
  State<AppAboutDialog> createState() => _AppAboutDialogState();
}

/// 把系统文字缩放乘上弹窗自己的比例：整体等比缩小的同时，
/// 不吞掉用户在系统里调过的字号。
class _ScaledTextScaler extends TextScaler {
  const _ScaledTextScaler(this.base, this.factor);

  final TextScaler base;
  final double factor;

  @override
  double scale(double fontSize) => base.scale(fontSize) * factor;

  /// 只为满足 [TextScaler] 的旧接口（已弃用）：按 1.0 号字取比例就够近似了
  @override
  double get textScaleFactor => scale(1.0);

  @override
  bool operator ==(Object other) =>
      other is _ScaledTextScaler &&
      other.base == base &&
      other.factor == factor;

  @override
  int get hashCode => Object.hash(base, factor);
}

class _AppAboutDialogState extends State<AppAboutDialog> {
  // 页脚是行内链接（TextSpan + recognizer），必须自己回收
  late final TapGestureRecognizer _authorTap = TapGestureRecognizer()
    ..onTap = () => _open(AppAboutDialog.authorUrl);
  late final TapGestureRecognizer _licenseTap = TapGestureRecognizer()
    ..onTap = () => _open(AppAboutDialog.licenseUrl);

  /// 内容区滚轮平滑（见 [SmoothScrollController]）
  final SmoothScrollController _scroll = SmoothScrollController();

  @override
  void dispose() {
    _authorTap.dispose();
    _licenseTap.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _open(String url) {
    unawaited(widget.openUrl(url));
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextStyle caption = theme.textTheme.bodySmall!.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final TextStyle linkStyle = caption.copyWith(
      color: scheme.onSurface,
      fontWeight: FontWeight.w500,
    );

    final double s = AppAboutDialog.scaleFor(MediaQuery.sizeOf(context));

    return Dialog(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: AppAboutDialog.designWidth * s),
        child: Stack(
          children: <Widget>[
            MediaQuery(
              // 整块内容一起缩：文字走 textScaler，盒子走下面的 s
              data: MediaQuery.of(context).copyWith(
                textScaler: _ScaledTextScaler(
                  MediaQuery.textScalerOf(context),
                  s,
                ),
              ),
              child: SingleChildScrollView(
                controller: _scroll,
                padding: EdgeInsets.fromLTRB(28 * s, 32 * s, 28 * s, 24 * s),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    // 图标本身就是圆角方块（1024 画布里留了白），不再套圆角裁一刀
                    Image.asset(
                      'assets/app_icon.png',
                      width: 128 * s,
                      height: 128 * s,
                      filterQuality: FilterQuality.medium,
                      semanticLabel: 'Lamp Player 图标',
                    ),
                    SizedBox(height: 18 * s),
                    Text(
                      'Lamp Player',
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 22 * s),
                    _VersionRow(version: 'v$appVersion', scale: s),
                    SizedBox(height: 18 * s),
                    Text(
                      '专注歌词与曲库的本地音乐播放器',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    SizedBox(height: 20 * s),
                    Text('技术栈', style: caption),
                    SizedBox(height: 10 * s),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8 * s,
                      runSpacing: 8 * s,
                      children: <Widget>[
                        for (final _Tech tech in _Tech.values)
                          _TechChip(tech: tech, scale: s),
                      ],
                    ),
                    SizedBox(height: 22 * s),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: _LinkButton(
                            // 内置图标集里没有 GitHub 标记，用自带字体里的字形
                            icon: LampIcons.github,
                            label: 'GitHub',
                            scale: s,
                            onTap: () => _open(AppAboutDialog.githubUrl),
                          ),
                        ),
                        SizedBox(width: 12 * s),
                        Expanded(
                          child: _LinkButton(
                            icon: Icons.history,
                            label: '更新日志',
                            scale: s,
                            onTap: () => _open(AppAboutDialog.changelogUrl),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 12 * s),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: _LinkButton(
                            icon: Icons.balance,
                            label: '开源许可',
                            scale: s,
                            onTap: () => _open(AppAboutDialog.licenseUrl),
                          ),
                        ),
                        SizedBox(width: 12 * s),
                        Expanded(
                          child: _LinkButton(
                            icon: Icons.bug_report_outlined,
                            label: '问题反馈',
                            scale: s,
                            onTap: () => _open(AppAboutDialog.issuesUrl),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 22 * s),
                    Text.rich(
                      TextSpan(
                        children: <InlineSpan>[
                          const TextSpan(text: '由 '),
                          TextSpan(
                            text: 'Linecos',
                            style: linkStyle,
                            recognizer: _authorTap,
                          ),
                          const TextSpan(text: ' 开发'),
                        ],
                      ),
                      textAlign: TextAlign.center,
                      style: caption,
                    ),
                    SizedBox(height: 2 * s),
                    Text.rich(
                      TextSpan(
                        children: <InlineSpan>[
                          TextSpan(
                            text: '© 2026 Linecos',
                            style: caption.copyWith(color: scheme.onSurface),
                          ),
                          const TextSpan(text: '  '),
                          TextSpan(
                            text: '开源许可',
                            style: linkStyle.copyWith(
                              decoration: TextDecoration.underline,
                              decorationColor: scheme.onSurfaceVariant,
                            ),
                            recognizer: _licenseTap,
                          ),
                        ],
                      ),
                      textAlign: TextAlign.center,
                      style: caption,
                    ),
                  ],
                ),
              ),
            ),
            // 与「修改封面 / 播放队列」那些弹窗一致：关闭在右上角
            Positioned(
              top: 6,
              right: 6,
              child: IconButton(
                tooltip: '关闭',
                iconSize: 20,
                visualDensity: VisualDensity.compact,
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 版本行：一条描边卡片，左边「Lamp Player 版本」，右边版本号 + 复制
class _VersionRow extends StatefulWidget {
  const _VersionRow({required this.version, required this.scale});

  final String version;

  /// 弹窗的缩放比例（见 [AppAboutDialog.scaleFor]）
  final double scale;

  @override
  State<_VersionRow> createState() => _VersionRowState();
}

class _VersionRowState extends State<_VersionRow> {
  bool _copied = false;
  Timer? _resetTimer;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.version));
    if (!mounted) {
      return;
    }
    setState(() => _copied = true);
    _resetTimer?.cancel();
    _resetTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) {
        setState(() => _copied = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final double s = widget.scale;
    return Container(
      height: 52 * s,
      padding: EdgeInsets.only(left: 16 * s, right: 6 * s),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(12 * s),
      ),
      child: Row(
        children: <Widget>[
          Text(
            'Lamp Player 版本',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          Text(
            widget.version,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(width: 2 * s),
          IconButton(
            tooltip: _copied ? '已复制' : '复制版本号',
            onPressed: _copy,
            // 行高是缩过的，按钮自己也给死尺寸（原来是默认 48 + compact 后的
            // 40），否则固定的点击区会把缩过的行撑出去
            padding: EdgeInsets.zero,
            constraints: BoxConstraints.tightFor(width: 40 * s, height: 40 * s),
            iconSize: 16 * s,
            visualDensity: VisualDensity.compact,
            icon: Icon(
              _copied ? Icons.check : Icons.content_copy,
              color: _copied ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 技术栈 chip：品牌色描边 + 同色小图标，颜色按主题调过对比度
class _TechChip extends StatelessWidget {
  const _TechChip({required this.tech, required this.scale});

  final _Tech tech;
  final double scale;

  /// 深色主题下品牌色本来就亮；浅色主题要往 onSurface 压深，否则浅色芯片
  /// 贴在近白底上几乎看不见（同理浅色下 Flutter 的 0xFF54C5F8）
  static Color colorOf(Color brand, ColorScheme scheme) {
    return scheme.brightness == Brightness.dark
        ? Color.lerp(brand, scheme.onSurface, 0.1)!
        : Color.lerp(brand, scheme.onSurface, 0.5)!;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color color = colorOf(tech.brand, scheme);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: 12 * scale,
        vertical: 6 * scale,
      ),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.55)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(tech.icon, size: 14 * scale, color: color),
          SizedBox(width: 6 * scale),
          Text(
            tech.label,
            style: theme.textTheme.labelMedium?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

/// 2×2 里的一个链接按钮：描边、居中图标 + 文字
class _LinkButton extends StatelessWidget {
  const _LinkButton({
    required this.icon,
    required this.label,
    required this.scale,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final double scale;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final double s = scale;
    return SizedBox(
      height: 50 * s,
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 18 * s, color: scheme.onSurfaceVariant),
        label: Text(label, style: theme.textTheme.bodyMedium),
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.onSurface,
          side: BorderSide(color: scheme.outlineVariant),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12 * s),
          ),
          padding: EdgeInsets.zero,
          // 默认 64×48 的最小尺寸与 48 的点击区都比缩过的按钮高，会撑出描边
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }
}
