"""生成 Lamp Player 的应用图标（exe / 托盘 / 侧栏品牌位共用一套几何图形）。

设计：深色圆角方块上挂一盏吊灯 —— 灯绳 + 梯形灯罩 + 灯口的光锥。
形状简单、左右对称，缩到 16px 仍然认得出来；灯罩用主题种子色 #FFB300。

用法（需要 Pillow）：
    C:/Python314/python.exe scripts/make_icon.py

产物：
    assets/app_icon.png           512×512，侧栏品牌位用
    assets/tray_icon.ico          16/20/24/32/40/48，托盘用
    windows/runner/resources/app_icon.ico
                                  16~256 七档，exe 图标用
"""

from __future__ import annotations

import pathlib

from PIL import Image, ImageDraw

ROOT = pathlib.Path(__file__).resolve().parent.parent
AMBER = (255, 179, 0)
AMBER_LIGHT = (255, 214, 102)
BACKDROP_TOP = (43, 33, 24)
BACKDROP_BOTTOM = (18, 15, 13)

# 先按 4 倍画再缩小：Pillow 没有抗锯齿，超采样是最省事的做法
SUPERSAMPLE = 4
MASTER = 1024
SCALE = MASTER * SUPERSAMPLE


def _px(ratio: float) -> float:
    """以画布边长比例给坐标，换尺寸时形状不会走形。"""
    return ratio * SCALE


def _vertical_gradient(size: int, top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    gradient = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / max(size - 1, 1)
        gradient.putpixel(
            (0, y),
            (
                round(top[0] + (bottom[0] - top[0]) * t),
                round(top[1] + (bottom[1] - top[1]) * t),
                round(top[2] + (bottom[2] - top[2]) * t),
            ),
        )
    return gradient.resize((size, size))


def render_master() -> Image.Image:
    canvas = _vertical_gradient(SCALE, BACKDROP_TOP, BACKDROP_BOTTOM).convert("RGBA")

    # 圆角遮罩：Windows 图标常见 22% 圆角，太方会显得是块色板
    mask = Image.new("L", (SCALE, SCALE), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, SCALE - 1, SCALE - 1), radius=_px(0.22), fill=255
    )
    canvas.putalpha(mask)

    light = Image.new("RGBA", (SCALE, SCALE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(light)

    # 灯罩下的光锥：上窄下宽的梯形，越往下越淡，像真的照在桌面上
    cone_top = 0.30
    cone_bottom = 0.86
    cone = Image.new("L", (SCALE, SCALE), 0)
    ImageDraw.Draw(cone).polygon(
        [
            (_px(0.5 - 0.055), _px(cone_top)),
            (_px(0.5 + 0.055), _px(cone_top)),
            (_px(0.5 + 0.27), _px(cone_bottom)),
            (_px(0.5 - 0.27), _px(cone_bottom)),
        ],
        fill=255,
    )
    # 竖向淡出：顶部最亮，底部收干净，避免一路灰到画布边缘
    fade = Image.new("L", (SCALE, SCALE), 0)
    fade_draw = ImageDraw.Draw(fade)
    steps = 96
    for step in range(steps):
        start = _px(cone_top) + (_px(cone_bottom) - _px(cone_top)) * step / steps
        end = _px(cone_top) + (_px(cone_bottom) - _px(cone_top)) * (step + 1) / steps
        value = round(210 * (1 - step / steps) ** 1.3)
        fade_draw.rectangle((0, start, SCALE, end + 1), fill=value)
    cone = Image.composite(fade, Image.new("L", (SCALE, SCALE), 0), cone)
    # 用 putalpha 而不是 paste(mask)：paste 会连颜色一起乘上遮罩，
    # 叠到画布上等于透明度平方，光锥会淡到看不见
    glow = Image.new("RGBA", (SCALE, SCALE), (*AMBER_LIGHT, 255))
    glow.putalpha(cone)
    light.alpha_composite(glow)
    draw = ImageDraw.Draw(light)

    # 灯绳
    draw.rounded_rectangle(
        (_px(0.487), _px(0.10), _px(0.513), _px(0.30)),
        radius=_px(0.013),
        fill=(120, 104, 92, 255),
    )

    # 灯罩：上窄下宽的梯形 + 圆角底边
    shade_top = _px(0.28)
    shade_bottom = _px(0.50)
    draw.polygon(
        [
            (_px(0.40), shade_top),
            (_px(0.60), shade_top),
            (_px(0.72), shade_bottom),
            (_px(0.28), shade_bottom),
        ],
        fill=(*AMBER, 255),
    )
    # 灯罩口加一道亮边，小尺寸下轮廓更清楚
    draw.rounded_rectangle(
        (_px(0.265), _px(0.478), _px(0.735), _px(0.512)),
        radius=_px(0.017),
        fill=(*AMBER_LIGHT, 255),
    )

    canvas = Image.alpha_composite(canvas, light)
    return canvas.convert("RGB")


def main() -> None:
    master = render_master()

    assets = ROOT / "assets"
    runner = ROOT / "windows" / "runner" / "resources"
    assets.mkdir(parents=True, exist_ok=True)

    def scaled(size: int) -> Image.Image:
        return master.resize((size, size), Image.LANCZOS).convert("RGBA")

    scaled(512).save(assets / "app_icon.png")

    tray_sizes = [16, 20, 24, 32, 40, 48]
    scaled(48).save(assets / "tray_icon.ico", sizes=[(s, s) for s in tray_sizes])

    app_sizes = [16, 24, 32, 48, 64, 128, 256]
    scaled(256).save(runner / "app_icon.ico", sizes=[(s, s) for s in app_sizes])

    for path in (
        assets / "app_icon.png",
        assets / "tray_icon.ico",
        runner / "app_icon.ico",
    ):
        print(f"{path.relative_to(ROOT)}  {path.stat().st_size} bytes")


if __name__ == "__main__":
    main()
