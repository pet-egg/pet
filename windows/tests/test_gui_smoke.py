"""오프스크린 GUI 스모크 테스트 — 리소스 로딩·렌더·메뉴·상태전환이 안 죽는지.

`QT_QPA_PLATFORM=offscreen` 로 디스플레이 없이 돈다(Mac·Windows CI 공통).
실제 스프라이트(pets/)를 읽으므로 리소스 경로 해석까지 함께 검증한다.
"""
import os
import sys

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pytest  # noqa: E402
from PySide6.QtGui import QPixmap  # noqa: E402
from PySide6.QtWidgets import QApplication  # noqa: E402

from pet_win import animation as anim  # noqa: E402
from pet_win import resources  # noqa: E402
from pet_win.spritesheet import SpriteSheet  # noqa: E402


@pytest.fixture(scope="module")
def qapp():
    app = QApplication.instance() or QApplication([])
    yield app


def test_pets_dir_found():
    assert os.path.isdir(resources.pets_dir()), resources.pets_dir()
    assert "totodile" in resources.available_slugs_on_disk()


def test_load_all_selectable_pets(qapp):
    from pet_win import petmeta
    for slug in petmeta.AVAILABLE_PET_SLUGS:
        sheet = SpriteSheet(slug, resources.pet_dir(slug))
        assert sheet.frame_w > 0 and sheet.frame_h > 0
        for state in (anim.IDLE, anim.RUNNING, anim.WAITING, anim.REVIEW,
                      anim.FAILED):
            a = sheet.animation(state)
            assert a.frames, f"{slug}/{state} 프레임 없음"
            assert len(a.frames) == len(a.durations_ms)
            assert not a.frames[0].isNull()


def test_window_renders_every_state(qapp):
    from pet_win.app import PetWindow
    win = PetWindow()
    try:
        for state in (anim.IDLE, anim.RUNNING, anim.WAITING, anim.REVIEW,
                      anim.FAILED):
            win._set_animation(state, force=True)
            win._advance_frame()
            pm = win.grab()   # paintEvent 를 정상 경로로 태워 렌더
            assert not pm.isNull()
            assert pm.width() > 0 and pm.height() > 0
        # 폴링(임의 상태) 한 번 — 예외 없이 도는지.
        win._poll()
        # 메뉴 구성 — 액션이 만들어지는지.
        menu = win._build_menu()
        assert menu.actions()
    finally:
        win.close()


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
