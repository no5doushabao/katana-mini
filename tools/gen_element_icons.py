#!/usr/bin/env python3
"""生成七元素像素图标（32x32，**几何原创造型**）。

⚠️⚠️ 2026-10-07 起：art/elements/ 里的图标**不是这个脚本生成的**！
    用户看了两套之后，选的是「**官方元素造型转像素画**」那一套
    （另有转换脚本负责把元素符号的高分辨率原图降采样 + 量化成 32x32 像素画。）
    **重跑本脚本会把 art/elements/ 覆盖回"几何原创风"** ——
    除非你就是想换回去（比如以后要发布、需要一套无版权尾巴的图标），否则别跑。
    几何风的备份留在 `_smoke/element-icons-32-geometric/`。

用法（在项目根目录下）：
    python tools/gen_element_icons.py

为什么图标是**代码生成**的，而不是下载现成的：
    原神的元素图标是米哈游的版权素材，直接用官方素材文件会破坏本项目
    一直守着的"不碰官方素材"这条线（游戏本体用的是 CC0 的 Kenney 素材）。
    这里用几何基元现画一套，风格与项目现有像素素材统一，且没有任何授权问题。

颜色取"接近但不完全相同"的通用元素配色 —— 颜色本身不受版权保护，
而符号造型（下宽上尖的火焰、六角星形的冰晶、三片草叶……）都是原创几何图形。

## 2026-10-07：24x24 -> 32x32，并加"描边 + 明暗"

用户看了 AI 洗完的 32x32 素材觉得"不错"，于是七元素图标统一升到 32x32。
这一版比 24x24 多的不只是分辨率，还有**三层结构**（这是 32 网格才养得起的）：

    描边（1px，各元素自己的深色）→ 主色 → 暗面 → 亮部

三层的好处：图标贴在敌人头顶时**有轮廓、不糊在背景里**，也**不再和敌人的本体染色撞色**。
描边用 MaxFilter 做形态学膨胀得到（见 compose），所以造型函数只管画"实心形状"，
不用手写描边坐标 —— 改造型时描边自动跟着走。

⚠️ 造型必须离画布边缘至少 2px（PAD），否则 1px 描边会被画布裁掉、出现"缺口"。

⚠️ 生成后必须让 Godot 重新导入，否则 load() 会返回 null **而且不报错**：
    godot --headless --path . --import
"""
from pathlib import Path
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

# Windows 上 Python 默认按 ANSI 代码页（本机 cp936）输出，print emoji 会**直接崩**：
#   UnicodeEncodeError: 'gbk' codec can't encode character '\u26a0'
# 这个脚本会跑在没配过 UTF-8 的环境里（不是每个环境都有 sitecustomize 兜底），
# 所以自己把标准流切到 UTF-8 —— 实测踩过一次，别删。
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

S = 32                                    # 图标边长
PAD = 2                                   # 造型离边缘的留白（给描边让位）
PROJECT = Path(__file__).resolve().parent.parent
OUT = PROJECT / "art" / "elements"

# 元素 -> (主色, 亮部色, 暗面/描边色)。键名 = 输出文件名 = 游戏里 element 字符串，
# 所以加新元素时只要在这里加一行 + 重跑脚本，GDScript 那边一行都不用改。
#
# 主色沿用 24x24 那一版的取值（和 EliteEnemy.gd 的 AURA_COLORS 是同一套色），
# 亮部/暗面由主色推导手感：亮部提亮、降饱和，暗面压暗到约 35% 亮度。
ELEMENTS = {
    "fire":    ((255, 107, 53), (255, 200, 87), (140, 44, 18)),
    "water":   ((63, 169, 245), (155, 217, 255), (24, 84, 158)),
    "wind":    ((78, 205, 196), (168, 240, 232), (22, 112, 108)),
    "thunder": ((166, 109, 212), (217, 184, 240), (84, 46, 132)),
    "grass":   ((122, 199, 79), (195, 232, 141), (52, 112, 30)),
    "ice":     ((127, 216, 247), (214, 244, 255), (46, 128, 176)),
    "rock":    ((224, 163, 62), (247, 217, 140), (132, 82, 18)),
}


# --------------------------------------------------------------------------
# 造型（32x32 网格，坐标 0..31，实际造型限制在 PAD..31-PAD 内）
#
# 每个函数收到三个 draw（都是 "L" 模式蒙版），按**从下到上**的顺序画：
#   m = 主色层（必画，决定外形轮廓）
#   s = 暗面层（可选，画在主色上面）
#   l = 亮部层（可选，画在最上面）
# 只有"实心形状"需要画出来，描边是自动膨胀出来的。
# --------------------------------------------------------------------------

def draw_fire(m, s, l):
    """火焰：下宽上尖的桃形，右下留暗面、内部一道亮焰。"""
    m.polygon([(16, 2), (20, 9), (23, 14), (24, 20), (21, 26), (16, 29),
               (11, 29), (8, 25), (7, 19), (9, 13), (12, 8)], fill=255)
    s.polygon([(16, 29), (21, 26), (24, 20), (22, 22), (18, 27)], fill=255)
    l.polygon([(16, 12), (19, 19), (18, 25), (14, 25), (13, 19)], fill=255)


def draw_water(m, s, l):
    """水滴：上尖下圆，右下暗面 + 内部圆形高光。"""
    m.polygon([(16, 2), (21, 10), (25, 18), (24, 24), (16, 29),
               (8, 24), (7, 18), (11, 10)], fill=255)
    s.polygon([(16, 29), (24, 24), (25, 18), (22, 21), (19, 26)], fill=255)
    l.ellipse([11, 16, 21, 26], fill=255)


def draw_wind(m, s, l):
    """风：三道右端带卷的气流，长度参差。

    这个造型改过三版，都在这一行注释里留个记录，免得下一个我又绕回去：
      24x24 v1：两条弧 + 中间一条直线 —— 读起来像"眉毛 + 波浪"
      32x32 v2：三条平行弧              —— 还是像"三道眉毛"（弧太完整、太对称）
      32x32 v3：现在这个 —— 气流不在"弧"，在"**右端的卷**"：
                每条都是水平流线，走到右端向下勾一个小卷，三条长度参差，
                读起来才像"风在往右吹"。对称 = 眉毛，参差 = 气流。
    """
    flows = [
        [(4, 9), (17, 9), (20, 11), (18, 14)],
        [(7, 16), (22, 16), (25, 18), (23, 21)],
        [(4, 23), (15, 23), (18, 25), (16, 28)],
    ]
    for pts in flows:
        m.line(pts, fill=255, width=3, joint="curve")
        # 高光：沿着流线的水平段上缘走一条 1px 亮线
        l.line([(pts[0][0], pts[0][1] - 1), (pts[1][0], pts[1][1] - 1)], fill=255, width=1)


def draw_thunder(m, s, l):
    """雷：闪电折线 + 内部亮条。"""
    m.polygon([(19, 2), (10, 15), (15, 15), (12, 29), (23, 13), (17, 13), (22, 2)],
              fill=255)
    l.polygon([(18, 6), (14, 13), (16, 13), (14, 20)], fill=255)


def draw_grass(m, s, l):
    """草：三片草叶从根部发散（中间直立、左右各一斜叶）。

    24x24 那一版画的是"两个并排椭圆"，读起来完全不像草 —— 小尺寸下，
    大色块轮廓才稳，细节越多越糊。32 网格上叶片能画宽一点了。
    """
    m.polygon([(15, 29), (15, 7), (18, 7), (18, 29)], fill=255)
    m.polygon([(15, 26), (5, 13), (7, 10), (17, 21)], fill=255)
    m.polygon([(18, 26), (28, 13), (26, 10), (16, 21)], fill=255)
    l.line([(16, 27), (16, 9)], fill=255, width=1)


def draw_ice(m, s, l):
    """冰：六角星（两个交叠的三角形）+ 中心亮核。

    24x24 那一版画的是"三条交叉线 + 六个小圆点"，放大后糊成一团、认不出是雪花。
    同 grass：小尺寸下，大色块轮廓比细节可靠得多。
    """
    m.polygon([(16, 2), (28, 23), (4, 23)], fill=255)
    m.polygon([(16, 30), (4, 9), (28, 9)], fill=255)
    l.ellipse([12, 12, 20, 20], fill=255)


def draw_rock(m, s, l):
    """岩：菱形晶石，右下暗面（光从左上）+ 内部亮菱形。"""
    m.polygon([(16, 2), (29, 16), (16, 30), (3, 16)], fill=255)
    s.polygon([(16, 30), (29, 16), (24, 16), (16, 24)], fill=255)
    l.polygon([(16, 6), (21, 16), (16, 26), (11, 16)], fill=255)


DRAWERS = {
    "fire": draw_fire, "water": draw_water, "wind": draw_wind,
    "thunder": draw_thunder, "grass": draw_grass, "ice": draw_ice, "rock": draw_rock,
}


def _mask(size: int):
    return Image.new("L", (size, size), 0)


def compose(size: int, drawer, cols) -> Image.Image:
    """把造型层合成为"描边 + 主色 + 暗面 + 亮部"的 RGBA 图标。

    描边不是手画的，而是把整体轮廓做 1px 形态学膨胀、再减去原轮廓得到的：
    这样换造型时描边自动跟着变，不会出现"描边和造型对不上"的经典 bug。
    """
    main, light, shade = _mask(size), _mask(size), _mask(size)
    drawer(ImageDraw.Draw(main), ImageDraw.Draw(shade), ImageDraw.Draw(light))

    outline_area = ImageChops.lighter(ImageChops.lighter(main, shade), light)
    grown = outline_area.filter(ImageFilter.MaxFilter(3))     # 3x3 膨胀 = 外扩 1px
    outline = ImageChops.subtract(grown, outline_area)

    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    # 从下到上：描边 -> 主色 -> 暗面 -> 亮部
    for mask, rgb in ((outline, cols[2]), (main, cols[0]), (shade, cols[2]), (light, cols[1])):
        img.paste(Image.new("RGBA", (size, size), rgb + (255,)), (0, 0), mask)
    return img


def overview(imgs: dict, zoom: int, path: Path) -> None:
    """出一张放大 + 带标注的总览图，方便肉眼确认造型（离线预览用）。"""
    from PIL import ImageFont
    pad, label_h = 14, 22
    w = len(imgs) * (S * zoom + pad) + pad
    canvas = Image.new("RGB", (w, S * zoom + label_h + pad * 2), (26, 28, 34))
    d = ImageDraw.Draw(canvas)
    try:
        font = ImageFont.truetype(r"C:\Windows\Fonts\msyh.ttc", 13)
    except Exception:
        font = ImageFont.load_default()
    for i, (name, src) in enumerate(imgs.items()):
        big = src.resize((S * zoom, S * zoom), Image.NEAREST)
        x, y = pad + i * (S * zoom + pad), pad
        d.rectangle([x - 2, y - 2, x + S * zoom + 1, y + S * zoom + 1], fill=(40, 44, 54))
        canvas.paste(big, (x, y), big)
        d.text((x + 4, y + S * zoom + 4), name, fill=(225, 232, 242), font=font)
    canvas.save(path)
    print("saved overview", path, canvas.size)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    made = {}
    for name, cols in ELEMENTS.items():
        img = compose(S, DRAWERS[name], cols)
        img.save(OUT / f"{name}.png")
        made[name] = img
        print("saved", OUT / f"{name}.png")
    print(f"\n共 {len(ELEMENTS)} 个图标（{S}x{S}）-> {OUT}")

    smoke = PROJECT.parent / "_smoke"
    if smoke.is_dir():
        overview(made, 8, smoke / "element-icons-32.png")

    print("⚠️ 记得跑 godot --headless --path . --import 让 Godot 导入新 PNG")


if __name__ == "__main__":
    main()
