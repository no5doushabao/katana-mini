#!/usr/bin/env python3
"""生成移动危险物的视觉贴图（art/hazard.png，24x24 红色八尖刺球）。

为什么需要单独生成一张：
    2026-10-07 用户报的 bug —— "最后一个高台右边空无一物，却会被杀"。
    根因：`tools/build_level.gd` 造 Hazard 时**只造了 Area2D、没造 Visual 子节点**，
    而 `Hazard.gd` 的 `_ready()` 只兜底 Shape（碰撞体）、**不兜底视觉** →
    危险物从头到尾没有视觉，碰撞体却在 → 玩家撞上"空气"就死。

为什么长这样：
    红色在平台游戏里是"致命"的通用视觉语言；尖刺让它在小尺寸下也一眼可辨。
    做法与元素图标完全一致（像素 + 深色描边 + 明暗），风格不会裂。

⚠️ 尺寸刻意比判定大：贴图 24x24，碰撞体仍是 18x18（见 build_level.gd 的 hazard_size）。
    **视觉比判定大**是故意的 —— 玩家看到 24px 的东西、只有中间 18px 会致死，
    判定比看起来宽松，手感更好（反过来"看着没碰到却死了"最招人恨）。

用法：
    uv run --with pillow python tools/gen_hazard_sprite.py
    ⚠️ 生成后要 `godot --headless --path . --import`，否则 load() 返回 null 且不报错。
"""
from pathlib import Path
import math
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

S = 24
PROJECT = Path(__file__).resolve().parent.parent
OUT = PROJECT / "art" / "hazard.png"

MAIN = (214, 69, 65)       # 主体红
LIGHT = (255, 150, 126)    # 亮部
DARK = (58, 16, 14)        # 描边


def spikes(n: int, out_r: float, in_r: float, cx: float, cy: float) -> list:
    """n 角星的顶点序列（外/内半径交替）。"""
    pts = []
    for i in range(n * 2):
        ang = math.radians(i * 360.0 / (n * 2) - 90.0)   # -90 = 第一个尖朝上
        r = out_r if i % 2 == 0 else in_r
        pts.append((cx + r * math.cos(ang), cy + r * math.sin(ang)))
    return pts


def main() -> None:
    main_mask = Image.new("L", (S, S), 0)
    light_mask = Image.new("L", (S, S), 0)
    dm = ImageDraw.Draw(main_mask)
    dl = ImageDraw.Draw(light_mask)

    cx = cy = (S - 1) / 2.0
    dm.polygon(spikes(8, 10.6, 5.0, cx, cy), fill=255)      # 八尖刺
    dm.ellipse([cx - 5.0, cy - 5.0, cx + 5.0, cy + 5.0], fill=255)   # 中心轮盘
    dl.ellipse([cx - 3.2, cy - 3.6, cx + 2.6, cy + 2.2], fill=255)   # 高光

    # 描边 = 整体轮廓膨胀 1px 再减去轮廓（和元素图标同一套做法）
    solid = ImageChops.lighter(main_mask, light_mask)
    outline = ImageChops.subtract(solid.filter(ImageFilter.MaxFilter(3)), solid)

    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    for mask, rgb in ((outline, DARK), (main_mask, MAIN), (light_mask, LIGHT)):
        img.paste(Image.new("RGBA", (S, S), rgb + (255,)), (0, 0), mask)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    img.save(OUT)
    print(f"saved {OUT}  {S}x{S}")
    print("⚠️ 记得 godot --headless --path . --import")


if __name__ == "__main__":
    main()
