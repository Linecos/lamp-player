import 'package:flutter/material.dart';

/// 侧栏品牌标记：一只黄灯泡。
///
/// 几何直接按图标稿量出来的（512 画布上的比例）：灯泡宽 0.36、圆头中心
/// y=0.404 半径 0.18、灯座宽 0.203 收到 y=0.717，灯丝是一个 Y（分叉 0.428、
/// 臂端 0.385、竖干到 0.512），灯座两道纹路在 0.564 / 0.617。比例也抄在
/// `scripts/make_icon.py` 里，侧栏 / exe / 托盘三处形状一致。
///
/// 深色模式给一块**纯黑**底板，浅色模式给一块**浅灰**底板：黄灯泡直接落在
/// 米白侧栏上会「渗」进背景，一块方底板既压住边缘，也和深色那版对上。
class LampBrandMark extends StatelessWidget {
  const LampBrandMark({super.key, this.size = 28});

  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _BulbMarkPainter(
        dark: Theme.of(context).brightness == Brightness.dark,
      ),
    );
  }
}

class _BulbMarkPainter extends CustomPainter {
  const _BulbMarkPainter({required this.dark});

  final bool dark;

  /// 灯泡本体（取自图标稿）
  static const Color _bulb = Color(0xFFFFB300);

  /// 灯丝与灯座纹路
  static const Color _ink = Color(0xFF1F1913);

  /// 浅色模式的底板：中性浅灰，比米白侧栏深一档，又不至于抢灯泡
  static const Color _lightTile = Color(0xFFD6D6D6);

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.shortestSide;
    double px(double ratio) => ratio * s;

    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(px(0.22))),
      Paint()..color = dark ? Colors.black : _lightTile,
    );

    canvas.drawPath(_body(px), Paint()..color = _bulb);

    // 灯丝：一个 Y。竖干偏长、两臂偏短，和图标稿一致
    canvas.drawPath(
      Path()
        ..moveTo(px(0.5), px(0.512))
        ..lineTo(px(0.5), px(0.428))
        ..lineTo(px(0.457), px(0.385))
        ..moveTo(px(0.5), px(0.428))
        ..lineTo(px(0.543), px(0.385)),
      Paint()
        ..color = _ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = px(0.030)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // 灯座上的两道纹路
    final Paint bar = Paint()..color = _ink;
    for (final double top in <double>[0.564, 0.617]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(px(0.449), px(top), px(0.551), px(top + 0.024)),
          Radius.circular(px(0.012)),
        ),
        bar,
      );
    }
  }

  /// 灯泡轮廓：圆头 ∪ 收窄的灯座。
  ///
  /// 灯座的上半段是两条从圆头赤道斜下来的边（0.325,0.42 → 0.3985,0.58），
  /// 这一段被圆头盖住，露出来的就是图标稿那条平滑的肩线；底部再收成一个小圆头。
  Path _body(double Function(double) px) {
    final Path neck = Path()
      ..moveTo(px(0.325), px(0.42))
      ..lineTo(px(0.3985), px(0.58))
      ..lineTo(px(0.3985), px(0.648))
      ..lineTo(px(0.402), px(0.678))
      ..lineTo(px(0.422), px(0.698))
      ..lineTo(px(0.455), px(0.710))
      ..lineTo(px(0.488), px(0.7165))
      ..lineTo(px(0.512), px(0.7165))
      ..lineTo(px(0.545), px(0.710))
      ..lineTo(px(0.578), px(0.698))
      ..lineTo(px(0.598), px(0.678))
      ..lineTo(px(0.6015), px(0.648))
      ..lineTo(px(0.6015), px(0.58))
      ..lineTo(px(0.675), px(0.42))
      ..close();

    return Path.combine(
      PathOperation.union,
      Path()..addOval(
        Rect.fromCircle(center: Offset(px(0.5), px(0.404)), radius: px(0.18)),
      ),
      neck,
    );
  }

  @override
  bool shouldRepaint(covariant _BulbMarkPainter oldDelegate) {
    return oldDelegate.dark != dark;
  }
}
