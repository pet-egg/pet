"""파괴광선 이펙트(assets/effects/hyper_beam.png)를 그린다.

불뿜기·물뿜기 이펙트는 이미지 생성 모델로 만든 그림이지만, 광선은 **굵기가 일정한
직선**이라 손으로 그리는 쪽이 모양을 정확히 잡는다. 같은 규격을 지킨다.

  - 오른쪽 끝이 입이다. 앱(FlameWindow)이 창의 오른쪽 가장자리를 입에 붙이고 왼쪽으로
    늘인다 — 펫이 왼쪽을 보고 있기 때문이다.
  - 도트 크기를 불·물 이펙트와 맞춘다: 저해상도로 그린 뒤 4배 최근접 확대.

다시 그리려면: python3 tooling/scripts/make_hyper_beam.py
"""
from pathlib import Path
from PIL import Image

W, H, SCALE = 60, 20, 4          # 240 x 80 로 확대된다 (불·물 이펙트 폭 240 과 같다)
CY = H // 2                       # 광선 중심선

OUTLINE = (176, 52, 12, 255)      # 바깥 테두리 — 도트 그림이 배경에서 떨어져 보이게
ORANGE  = (255, 128, 24, 255)
YELLOW  = (255, 214, 64, 255)
CORE    = (255, 252, 214, 255)
WHITE   = (255, 255, 255, 255)

img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
px = img.load()

def put(x, y, c):
    if 0 <= x < W and 0 <= y < H:
        px[x, y] = c

# 1) 광선 몸통 — 굵기가 일정하다. 끝(왼쪽 x<6)만 살짝 가늘어진다.
#
# 앱은 이 그림을 길이에 맞춰 **통째로** 늘린다(높이 = 길이 / 가로세로비). 그래서 그림을
# 위아래로 넉넉히 잡으면 진화형(광선 길이 3.75배)에서 광선이 몸보다 굵어진다. 처음 26줄로
# 그렸을 때 망나뇽 몸통보다 섬광이 컸다 — 20줄로 줄였다.
for x in range(2, W - 4):
    taper = 0 if x >= 6 else (6 - x) // 2
    bands = [(4 - taper, OUTLINE), (3 - taper, ORANGE), (2 - taper, YELLOW), (1 - taper, CORE), (0, WHITE)]
    for half, c in bands:
        if half < 0:
            continue
        for dy in range(-half, half + 1):
            put(x, CY + dy, c)

# 2) 입 쪽 섬광 — 모은 힘이 터지는 자리라 광선보다 조금 크다. 너무 크면 펫 얼굴보다
#    섬광이 먼저 눈에 들어온다.
fx = W - 4
for r, c in [(6, OUTLINE), (5, ORANGE), (4, YELLOW), (3, CORE), (1, WHITE)]:
    for y in range(-r, r + 1):
        for x in range(-r, r + 1):
            if x * x + y * y <= r * r:
                put(fx + x, CY + y, c)
# 섬광의 십자 빛줄기
for d in range(7, 9):
    for c, off in [(YELLOW, 0)]:
        put(fx, CY - d, c); put(fx, CY + d, c)

# 3) 광선 둘레의 불티 — 정적인 막대처럼 보이지 않게.
for x, y, c in [(10, CY - 6, YELLOW), (17, CY + 6, ORANGE), (24, CY - 7, YELLOW),
                (31, CY + 6, YELLOW), (38, CY - 6, ORANGE), (45, CY + 7, YELLOW),
                (14, CY + 5, CORE), (34, CY - 5, CORE)]:
    put(x, y, c)

out = Path(__file__).resolve().parents[2] / "assets" / "effects" / "hyper_beam.png"
img.resize((W * SCALE, H * SCALE), Image.NEAREST).save(out)
print(f"wrote {out} ({W * SCALE}x{H * SCALE})")
