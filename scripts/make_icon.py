"""生成 Lamp Player 的应用图标（exe / 托盘 / 侧栏品牌位共用一套几何图形）。

设计：一只黄灯泡 —— 圆头 + 灯座 + Y 形灯丝 + 两道灯座纹路。
形状左右对称、笔画粗，缩到 16px 仍然认得出来；灯泡用 #FFC10A。

几何比例与 `lib/src/features/library/widgets/lamp_brand_mark.dart` 里的矢量
画法保持一致（圆头中心 0.5/0.40 半径 0.275、灯座 0.58–0.735、灯丝 0.412–0.558、
两道纹路在 0.604 / 0.660），两处切换时形状不会跳。

深色观感用**纯黑**圆角底板（exe / 应用图标），托盘则用透明底 —— 托盘图标
直接贴在任务栏上，带底板会多出一块方色块。

用法（需要 Pillow）：
    python -m pip install pillow
    python scripts/make_icon.py

产物：
    assets/app_icon.png           512×512，深色底板版
    assets/tray_icon.ico          16/20/24/32/40/48，透明底，托盘用
    windows/runner/resources/app_icon.ico
                                  16~256 七档，exe 图标用
"""

from __future__ import annotations

import pathlib

from PIL import Image, ImageDraw

ROOT = pathlib.Path(__file__).resolve().parent.parent

BULB = (255, 179, 0)
INK = (31, 25, 19)
BACKDROP = (0, 0, 0)

# 灯泡轮廓（画布边长比例）。数字直接按图标稿量出来的：圆头中心 0.5/0.404、
# 半径 0.18，灯座从 0.58 的 0.203 宽一路收到 y=0.7165 的小圆头。
_NECK = (
    (0.3250, 0.4200),
    (0.3985, 0.5800),
    (0.3985, 0.6480),
    (0.4020, 0.6780),
    (0.4220, 0.6980),
    (0.4550, 0.7100),
    (0.4880, 0.7165),
    (0.5120, 0.7165),
    (0.5450, 0.7100),
    (0.5780, 0.6980),
    (0.5980, 0.6780),
    (0.6015, 0.6480),
    (0.6015, 0.5800),
    (0.6750, 0.4200),
)
_FILAMENT = (
    ((0.5000, 0.5120), (0.5000, 0.4280)),
    ((0.5000, 0.4280), (0.4570, 0.3850)),
    ((0.5000, 0.4280), (0.5430, 0.3850)),
)

# 先按 4 倍画再缩小：Pillow 没有抗锯齿，超采样是最省事的做法
SUPERSAMPLE = 4
MASTER = 1024
SCALE = MASTER * SUPERSAMPLE


def _px(ratio: float) -> float:
    """以画布边长比例给坐标，换尺寸时形状不会走形。"""
    return ratio * SCALE


def _dot(draw: ImageDraw.ImageDraw, x: float, y: float, radius: float, color) -> None:
    draw.ellipse(
        (_px(x - radius), _px(y - radius), _px(x + radius), _px(y + radius)),
        fill=color,
    )


def _bulb_layer() -> Image.Image:
    """透明底上的灯泡本体（含灯丝与灯座纹路）。"""
    layer = Image.new("RGBA", (SCALE, SCALE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)

    # 灯泡 = 圆头 + 收窄的灯座（两笔同色，交界处自然合成一个轮廓）
    draw.polygon([(_px(x), _px(y)) for x, y in _NECK], fill=(*BULB, 255))
    _dot(draw, 0.5, 0.404, 0.18, (*BULB, 255))

    ink = (*INK, 255)
    stroke = max(1, round(_px(0.030)))

    # 灯丝：一个 Y。Pillow 的 line 没有圆头端点，末端补小圆点
    for (x1, y1), (x2, y2) in _FILAMENT:
        draw.line([(_px(x1), _px(y1)), (_px(x2), _px(y2))], fill=ink, width=stroke)
    for x, y in {p for pair in _FILAMENT for p in pair}:
        _dot(draw, x, y, 0.015, ink)

    # 灯座上的两道纹路
    for top in (0.564, 0.617):
        draw.rounded_rectangle(
            (_px(0.449), _px(top), _px(0.551), _px(top + 0.024)),
            radius=_px(0.012),
            fill=ink,
        )

    return layer


def render_tile() -> Image.Image:
    """纯黑圆角底板 + 灯泡：exe / 应用图标用。"""
    canvas = Image.new("RGBA", (SCALE, SCALE), (0, 0, 0, 0))
    ImageDraw.Draw(canvas).rounded_rectangle(
        (0, 0, SCALE - 1, SCALE - 1), radius=_px(0.22), fill=(*BACKDROP, 255)
    )
    canvas.alpha_composite(_bulb_layer())
    return canvas


def render_plain() -> Image.Image:
    """透明底 + 灯泡：托盘用。"""
    return _bulb_layer()


def main() -> None:
    assets = ROOT / "assets"
    runner = ROOT / "windows" / "runner" / "resources"
    assets.mkdir(parents=True, exist_ok=True)

    tile = render_tile().resize((MASTER, MASTER), Image.LANCZOS)
    plain = render_plain().resize((MASTER, MASTER), Image.LANCZOS)

    def sized(image: Image.Image, size: int) -> Image.Image:
        return image.resize((size, size), Image.LANCZOS).convert("RGBA")

    sized(tile, 512).save(assets / "app_icon.png")

    tray_sizes = [16, 20, 24, 32, 40, 48]
    sized(plain, 48).save(
        assets / "tray_icon.ico", sizes=[(s, s) for s in tray_sizes]
    )

    app_sizes = [16, 24, 32, 48, 64, 128, 256]
    sized(tile, 256).save(
        runner / "app_icon.ico", sizes=[(s, s) for s in app_sizes]
    )

    for path in (
        assets / "app_icon.png",
        assets / "tray_icon.ico",
        runner / "app_icon.ico",
    ):
        print(f"{path.relative_to(ROOT)}  {path.stat().st_size} bytes")


if __name__ == "__main__":
    main()
