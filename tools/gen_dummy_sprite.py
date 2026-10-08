#!/usr/bin/env python3
"""生成"训练假人"（木桩）的视觉贴图 —— art/dummy.png（24x24）。

为什么要它（2026-10-08 阿包提的）：
    唯一的精英被改成"无限血木桩"之后，它和真正的精英**长得一模一样** ——
    玩家打上去之前分不清"这是沙包还是会伤人的怪"。
    阿包原话：「木桩是木桩，精英是精英，这两个东西还是有本质区别的，
    要不然木桩换个贴图？」

为什么长这样（造型由阿包从 4 个候选里挑的 A）：
    稻草脑袋 + 十字横木 + 稻草袖口 —— 一眼"训练场里的假人"。
    ⚠️ **刻意不用红白靶心**：项目里红色是"致命"的视觉语言
    （见 gen_hazard_sprite.py 的注释），而木桩是绝对安全的沙包，
    用红色会自相矛盾。这里靠"稻草黄 + 木色"和灰蓝橙的敌人拉开距离。

⚠️ 规格必须和精英视觉对齐，否则像素密度不一致、风格会裂：
    24x24 贴图 + scale 2.0（= 屏幕上 48x48），和 enemy_sheet 第一帧同规格。

用法：
    python tools/gen_dummy_sprite.py
    ⚠️ 生成后必须 `godot --headless --path . --import`，
       否则新 PNG 的 load() 返回 null 而且**不报错**（§8.1 的老坑）。
"""
from pathlib import Path
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

S = 24
PROJECT = Path(__file__).resolve().parent.parent
OUT = PROJECT / "art" / "dummy.png"

WOOD = (139, 94, 60)
WOOD_LIGHT = (176, 128, 84)
STRAW = (214, 180, 96)
STRAW_LIGHT = (240, 214, 140)
DARK = (38, 24, 16)


def new_mask():
    m = Image.new("L", (S, S), 0)
    return m, ImageDraw.Draw(m)


def layer(img, mask, rgb):
    img.paste(Image.new("RGBA", (S, S), rgb + (255,)), (0, 0), mask)


def main() -> None:
    body, db = new_mask()
    light, dl = new_mask()
    straw, ds = new_mask()
    straw_l, dsl = new_mask()

    db.rectangle([9, 10, 14, 23], fill=255)             # 立柱
    db.rectangle([4, 12, 19, 14], fill=255)             # 十字横木（手臂）
    dl.rectangle([9, 10, 11, 23], fill=255)             # 立柱亮面
    ds.ellipse([7, 3, 16, 11], fill=255)                # 稻草脑袋
    dsl.ellipse([8, 4, 12, 8], fill=255)                # 稻草亮部
    ds.rectangle([3, 11, 5, 15], fill=255)              # 左袖口稻草
    ds.rectangle([18, 11, 20, 15], fill=255)            # 右袖口稻草
    db.rectangle([10, 15, 13, 17], fill=255)            # 腰带（深色木）

    # 描边 = 所有实心部分膨胀 1px 再减去自身（和元素图标 / hazard 同一套做法）
    solid = body
    for m in (straw, straw_l):
        solid = ImageChops.lighter(solid, m)
    outline = ImageChops.subtract(solid.filter(ImageFilter.MaxFilter(3)), solid)

    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    for mask, rgb in ((outline, DARK), (body, WOOD), (light, WOOD_LIGHT),
                      (straw, STRAW), (straw_l, STRAW_LIGHT)):
        layer(img, mask, rgb)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    img.save(OUT)
    print("saved %s  %dx%d" % (OUT, S, S))
    print("⚠️ 记得 godot --headless --path . --import")


if __name__ == "__main__":
    main()
