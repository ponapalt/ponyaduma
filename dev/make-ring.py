"""ポモドーロの進捗リング画像を作る（開発用。配布物には入らない: .narignore）。

使い方:  python dev/make-ring.py [出力先フォルダ]   （既定は shell/master）

作るもの（52x52 の透過 PNG。12 時の位置から時計回りに満ちていく）:
  surface3000.png 〜 surface3060.png   集中リング（0/60 〜 60/60）
  surface3100.png 〜 surface3160.png   休憩リング（0/60 〜 60/60）
  surface3200.png                      一時停止ボタン（⏸。サークルの中央。集中中・休憩中に出す）
  surface3201.png                      再開ボタン（▶。一時停止中に ⏸ の代わりに出す）
  surface3202.png                      休憩を飛ばすボタン（▶|。休憩中に出す）

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

BUTTON_BG = (64, 64, 76, 150)    # ボタンの下地（リングの穴を暗く半透明にして、どんな壁紙でもアイコンを読めるようにする）
BUTTON_ICON = (246, 246, 250, 255)   # ボタンのアイコン
R_BUTTON = R_IN - 1.5            # ボタンの下地の半径（リングの縁取りの内側ぴったり）。当たり判定は surfaces.txt の PomoPause

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


def make_button(kind):
    """サークル中央のボタン。kind は 'pause'（⏸）、'play'（▶）、'skip'（▶|）。"""
    c = SIZE / 2.0
    bg = Image.new("L", (SIZE * SS, SIZE * SS), 0)
    d = ImageDraw.Draw(bg)
    d.ellipse([CENTER - R_BUTTON * SS, CENTER - R_BUTTON * SS, CENTER + R_BUTTON * SS, CENTER + R_BUTTON * SS], fill=255)
    icon = Image.new("L", (SIZE * SS, SIZE * SS), 0)
    d = ImageDraw.Draw(icon)
    if kind == "pause":
        for x0, x1 in ((c - 6, c - 2), (c + 2, c + 6)):
            d.rectangle([x0 * SS, (c - 6) * SS, x1 * SS - 1, (c + 6) * SS - 1], fill=255)
    elif kind == "skip":
        # ▶|（休憩を飛ばして、次の集中へ）
        d.polygon([((c - 6) * SS, (c - 6) * SS), ((c - 6) * SS, (c + 6) * SS), ((c + 2) * SS, c * SS)], fill=255)
        d.rectangle([(c + 4) * SS, (c - 6) * SS, (c + 6) * SS - 1, (c + 6) * SS - 1], fill=255)
    else:
        d.polygon([((c - 4.0) * SS, (c - 7.0) * SS), ((c - 4.0) * SS, (c + 7.0) * SS), ((c + 7.0) * SS, c * SS)], fill=255)
    img = Image.new("RGBA", (SIZE * SS, SIZE * SS), (0, 0, 0, 0))
    img = Image.alpha_composite(img, layer(BUTTON_BG, bg))
    img = Image.alpha_composite(img, layer(BUTTON_ICON, icon))
    return img.convert("RGBa").resize((SIZE, SIZE), Image.BOX).convert("RGBA")


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "shell", "master")
    os.makedirs(out, exist_ok=True)
    for base, color in ((3000, FOCUS), (3100, BREAK)):
        for k in range(STEPS + 1):
            path = os.path.join(out, "surface%d.png" % (base + k))
            make_frame(color, k).save(path)
    make_button("pause").save(os.path.join(out, "surface3200.png"))
    make_button("play").save(os.path.join(out, "surface3201.png"))
    make_button("skip").save(os.path.join(out, "surface3202.png"))
    print("wrote %d images to %s" % ((STEPS + 1) * 2 + 3, os.path.abspath(out)))


if __name__ == "__main__":
    main()
