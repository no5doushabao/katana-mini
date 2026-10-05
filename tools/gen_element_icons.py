#!/usr/bin/env python3
"""生成七元素像素图标（24x24）到 art/elements/。

用法（在项目根目录下）：
    python tools/gen_element_icons.py

为什么图标是**代码生成**的，而不是下载现成的：
    原神的元素图标是米哈游的版权素材，直接用官方素材文件会破坏本项目
    一直守着的"不碰官方素材"这条线（游戏本体用的是 CC0 的 Kenney 素材）。
    这里用几何基元现画一套，风格与项目现有像素素材统一，且没有任何授权问题。

颜色取"接近但不完全相同"的通用元素配色 —— 颜色本身不受版权保护，
而符号造型（下宽上尖的火焰、六角星形的冰晶、三片草叶……）都是原创几何图形。

⚠️ 生成后必须让 Godot 重新导入，否则 load() 会返回 null **而且不报错**：
    godot --headless --path . --import
"""
from pathlib import Path
import sys

from PIL import Image, ImageDraw

# Windows 上 Python 默认按 ANSI 代码页（本机 cp936）输出，print emoji 会**直接崩**：
#   UnicodeEncodeError: 'gbk' codec can't encode character '\u26a0'
# 这个脚本会跑在没配过 UTF-8 的环境里（不是每个环境都有 sitecustomize 兜底），
# 所以自己把标准流切到 UTF-8 —— 实测踩过一次，别删。
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

S = 24                                    # 图标边长（与项目角色精灵同尺寸）
PROJECT = Path(__file__).resolve().parent.parent
OUT = PROJECT / "art" / "elements"

# 元素 -> (主色, 亮部色)。键名 = 输出文件名 = 游戏里 element 字符串，
# 所以加新元素时只要在这里加一行 + 重跑脚本，GDScript 那边一行都不用改。
ELEMENTS = {
    "fire":    ((255, 107, 53), (255, 200, 87)),
    "water":   ((63, 169, 245), (155, 217, 255)),
    "wind":    ((78, 205, 196), (168, 240, 232)),
    "thunder": ((166, 109, 212), (217, 184, 240)),
    "grass":   ((122, 199, 79), (195, 232, 141)),
    "ice":     ((127, 216, 247), (214, 244, 255)),
    "rock":    ((224, 163, 62), (247, 217, 140)),
}


def fire(d, c1, c2):
    """火焰：下宽上尖，右侧一道火舌；内焰用亮色。"""
    d.polygon([(12, 2), (15, 8), (18, 12), (17, 18), (12, 21), (7, 21), (5, 17),
               (6, 12), (9, 7)], fill=c1)
    d.polygon([(12, 9), (14, 14), (13, 18), (10, 18), (9, 14)], fill=c2)


def water(d, c1, c2):
    """水滴：上尖下圆。"""
    d.polygon([(12, 2), (17, 11), (18, 15), (12, 21), (6, 15), (7, 11)], fill=c1)
    d.ellipse([8, 12, 16, 20], fill=c1)
    d.ellipse([10, 14, 14, 18], fill=c2)


def wind(d, c1, c2):
    """风：两道向右收的气流弧 + 一道引导线。"""
    d.arc([1, 4, 17, 14], 205, 345, fill=c1, width=3)
    d.arc([6, 10, 23, 20], 205, 335, fill=c1, width=3)
    d.line([(4, 12), (15, 12)], fill=c2, width=2)


def thunder(d, c1, c2):
    """雷：闪电折线。"""
    d.polygon([(14, 2), (7, 12), (11, 12), (9, 22), (17, 10), (13, 10), (16, 2)], fill=c1)
    d.polygon([(13, 5), (10, 11), (12, 11), (11, 16)], fill=c2)


def grass(d, c1, c2):
    """草：三片草叶从根部发散。

    第一版画的是"两个并排椭圆"，读起来完全不像草 —— 24x24 这个尺寸下，
    大色块轮廓才稳，细节越多越糊。
    """
    d.polygon([(11, 22), (11, 7), (13, 7), (13, 22)], fill=c1)
    d.polygon([(11, 20), (4, 10), (6, 8), (13, 18)], fill=c1)
    d.polygon([(13, 20), (20, 10), (18, 8), (11, 18)], fill=c1)
    d.line([(12, 21), (12, 9)], fill=c2, width=1)


def ice(d, c1, c2):
    """冰：六角星（两个交叠的三角形）。

    第一版画的是"三条交叉线 + 六个小圆点"，放大后糊成一团、认不出是雪花。
    同 grass：小尺寸下，大色块轮廓比细节可靠得多。
    """
    d.polygon([(12, 2), (20, 16), (4, 16)], fill=c1)
    d.polygon([(12, 22), (4, 8), (20, 8)], fill=c1)
    d.ellipse([9, 9, 15, 15], fill=c2)


def rock(d, c1, c2):
    """岩：菱形晶石 + 内部高光。"""
    d.polygon([(12, 2), (21, 12), (12, 22), (3, 12)], fill=c1)
    d.polygon([(12, 7), (16, 12), (12, 17), (8, 12)], fill=c2)


DRAWERS = {
    "fire": fire, "water": water, "wind": wind, "thunder": thunder,
    "grass": grass, "ice": ice, "rock": rock,
}


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for name, (c1, c2) in ELEMENTS.items():
        img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        DRAWERS[name](ImageDraw.Draw(img), c1, c2)
        img.save(OUT / f"{name}.png")
        print("saved", OUT / f"{name}.png")
    print(f"\n共 {len(ELEMENTS)} 个图标 -> {OUT}")
    print("⚠️ 记得跑 godot --headless --path . --import 让 Godot 导入新 PNG")


if __name__ == "__main__":
    main()
