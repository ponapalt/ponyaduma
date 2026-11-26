"""ポモドーロの進捗リング画像を作る（開発用。配布物には入らない: .narignore）。

使い方:  python dev/make-ring.py [出力先フォルダ]   （既定は shell/master）

作るもの（52x52 の透過 PNG。12 時の位置から時計回りに満ちていく）:
  surface3000.png 〜 surface3060.png   集中リング（0/60 〜 60/60）
  surface3100.png 〜 surface3160.png   休憩リング（0/60 〜 60/60）

色や太さを変えるときは、下の定数を書き換えて、もう一度実行する。
画像の置き場所（座標）は shell/master/surfaces.txt の animation3000〜、3100〜 の pattern にある。
shell/master/ の既存の画像（さゆりしゅ様のもの）は読まないし、書き換えない。
"""
import math
import os
import sys

from PIL import Image, ImageDraw

SIZE = 52              # 画像の一辺（px）
SS = 8                 # 描画時の拡大率（アンチエイリアス用）
R_OUT = 24.0           # リングの外半径
R_IN = 16.0            # リングの内半径（太さ = R_OUT - R_IN）
STEPS = 60             # 段数（0〜STEPS）。変えたら surfaces.txt / descript.txt / pomodoro.txt の段数も合わせる

TRACK = (246, 246, 250, 235)     # 未到達部分（ほぼ白）
EDGE = (64, 64, 76, 200)         # 縁取り（半透明。シェルは seriko.use_self_alpha,1 なので、アルファはそのまま使われる）
FOCUS = (242, 85, 44, 255)       # 集中: トマトの赤橙
BREAK = (43, 181, 160, 255)      # 休憩: 青緑

CENTER = SIZE * SS / 2.0


def ring_mask(r_out, r_in):
    """r_in〜r_out の輪の形の、白黒マスクを返す。"""
    m = Image.new("L", (SIZE * SS, SIZE * SS), 0)
    d = ImageDraw.Draw(m)
    d.ellipse([CENTER - r_out * SS, CENTER - r_out * SS, CENTER + r_out * SS, CENTER + r_out * SS], fill=255)
    d.ellipse([CENTER - r_in * SS, CENTER - r_in * SS, CENTER + r_in * SS, CENTER + r_in * SS], fill=0)
    return m


def arc_mask(steps_done):
    """12 時から時計回りに steps_done/STEPS だけ満ちた扇形のマスク。"""
    m = Image.new("L", (SIZE * SS, SIZE * SS), 0)
    if steps_done <= 0:
        return m
    d = ImageDraw.Draw(m)
    box = [CENTER - R_OUT * SS * 1.2, CENTER - R_OUT * SS * 1.2, CENTER + R_OUT * SS * 1.2, CENTER + R_OUT * SS * 1.2]
    if steps_done >= STEPS:
        d.ellipse(box, fill=255)
    else:
        d.pieslice(box, start=-90, end=-90 + 360.0 * steps_done / STEPS, fill=255)
    return m


def multiply(a, b):
    from PIL import ImageChops
    return ImageChops.multiply(a, b)


def layer(rgba, mask):
    """単色 rgba を、マスクの濃さ（と rgba 自身のアルファ）で切り抜いたレイヤー。"""
    r, g, b, a = rgba
    alpha = mask.point(lambda v: v * a // 255)
    lay = Image.new("RGBA", mask.size, (r, g, b, 0))
    lay.putalpha(alpha)
    return lay


def make_frame(color, k):
    """縁取り → 未到達部分 → 満ちた部分 の順に、正しく重ねる（alpha_composite）。
    縮小はアルファ乗算済み（RGBa）で行い、半透明の境界に余計な色が混ざらないようにする。"""
    img = Image.new("RGBA", (SIZE * SS, SIZE * SS), (0, 0, 0, 0))
    img = Image.alpha_composite(img, layer(EDGE, ring_mask(R_OUT + 1.5, R_IN - 1.5)))
    img = Image.alpha_composite(img, layer(TRACK, ring_mask(R_OUT, R_IN)))
    img = Image.alpha_composite(img, layer(color, multiply(ring_mask(R_OUT, R_IN), arc_mask(k))))
    small = img.convert("RGBa").resize((SIZE, SIZE), Image.BOX)
    return small.convert("RGBA")


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "shell", "master")
    os.makedirs(out, exist_ok=True)
    for base, color in ((3000, FOCUS), (3100, BREAK)):
        for k in range(STEPS + 1):
            path = os.path.join(out, "surface%d.png" % (base + k))
            make_frame(color, k).save(path)
    print("wrote %d images to %s" % ((STEPS + 1) * 2, os.path.abspath(out)))


if __name__ == "__main__":
    main()
