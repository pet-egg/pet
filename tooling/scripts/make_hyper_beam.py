"""파괴광선 이펙트(assets/effects/hyper_beam.png)를 그린다.

불뿜기·물뿜기 이펙트는 이미지 생성 모델로 만든 그림이지만, 광선은 **굵기가 일정한
직선**이라 손으로 그리는 쪽이 모양을 정확히 잡는다. 같은 규격을 지킨다.

  - 오른쪽 끝이 입이다. 앱(FlameWindow)이 창의 오른쪽 가장자리를 입에 붙이고 왼쪽으로
    늘인다 — 펫이 왼쪽을 보고 있기 때문이다.
  - 저해상도로 그린 뒤 4배 최근접 확대한다(불·물 이펙트와 같은 방식).

다시 그리려면: python3 tooling/scripts/make_hyper_beam.py
"""
from pathlib import Path
from PIL import Image

W, H, SCALE = 120, 10, 4         # 480 x 40 — 가로세로비 12
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

# 앱은 이 그림을 길이에 맞춰 **통째로** 늘린다(높이 = 길이 / 가로세로비). 굵기는 그림의
# 가로세로비로만 정해진다. 불·물(3.0)과 같은 비로 그렸더니 망나뇽에서 광선 높이가 몸보다
# 컸다(400 vs 240 프레임 px). 가로세로비 12 면 grow=1.0 에서 광선 높이가 몸의 약 1/4~2/5:
#   미뇽 33/132 · 신뇽 63/195 · 망나뇽 100/240 (프레임 px, 섬광 포함 전체 높이)

# 1) 광선 몸통 — 굵기가 일정하다. 끝(왼쪽 x<8)만 가늘어진다. 섬광보다 한 줄씩 얇다.
for x in range(1, W - 5):
    taper = 0 if x >= 8 else (8 - x) // 3
    bands = [(3 - taper, OUTLINE), (2 - taper, ORANGE), (1 - taper, YELLOW), (0, WHITE if taper == 0 else YELLOW)]
    for half, c in bands:
        if half < 0:
            continue
        for dy in range(-half, half + 1):
            put(x, CY + dy, c)

# 2) 입 쪽 섬광 — 광선보다 조금 크다. **그림 안에 다 들어가야 한다**: 중심을 오른쪽 끝에서
#    반지름+1 만큼 안쪽에 둔다. 예전에는 중심 W-4 · 반지름 6 이라 오른쪽이 잘려 평평한
#    세로 단면이 남았다.
R = 4
fx = W - 1 - R
for r, c in [(R, OUTLINE), (R - 1, ORANGE), (R - 2, YELLOW), (1, WHITE)]:
    for y in range(-r, r + 1):
        for x in range(-r, r + 1):
            if x * x + y * y <= r * r:
                put(fx + x, CY + y, c)
assert all(px[W - 1, y][3] == 0 or abs(y - CY) == 0 for y in range(H)), "섬광이 오른쪽 변에 잘렸다"

# 3) 광선 둘레의 불티 — 정적인 막대처럼 보이지 않게.
for x, y, c in [(12, CY - 4, YELLOW), (26, CY + 4, ORANGE), (40, CY - 4, YELLOW),
                (55, CY + 4, YELLOW), (70, CY - 4, ORANGE), (86, CY + 4, YELLOW),
                (19, CY + 4, CORE), (62, CY - 4, CORE)]:
    put(x, y, c)

out = Path(__file__).resolve().parents[2] / "assets" / "effects" / "hyper_beam.png"
img.resize((W * SCALE, H * SCALE), Image.NEAREST).save(out)
print(f"wrote {out} ({W * SCALE}x{H * SCALE})")
