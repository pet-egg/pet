"""이브이 분기 진화 선택창.

이브이가 2억 토큰에 도달하면 8종의 진화형 중 하나를 고르는 온보딩식 그리드 창.
각 칸은 그 진화형의 idle 첫 프레임 썸네일 + 한글 이름. mac 의 EeveelutionChooser 와 짝.
"""
from __future__ import annotations

from PySide6.QtCore import Qt, QSize
from PySide6.QtGui import QIcon
from PySide6.QtWidgets import (QDialog, QGridLayout, QLabel, QPushButton,
                               QVBoxLayout)

from . import petmeta, resources
from .spritesheet import SpriteSheet


class EeveelutionChooser(QDialog):
    def __init__(self, korean_name, parent=None):
        super().__init__(parent)
        self.chosen: str | None = None
        self.setWindowTitle("이브이 진화형 선택")
        self.setModal(True)
        self.setStyleSheet(
            "QDialog{background:#1e1f22;}"
            "QLabel#title{color:#f0f0f0;font-size:15px;font-weight:600;}"
            "QLabel#sub{color:#9a9a9a;font-size:11px;}"
            "QPushButton{background:#2b2d31;color:#e8e8e8;border:1px solid #3a3c40;"
            "border-radius:10px;padding:8px;}"
            "QPushButton:hover{border:1px solid #6b8afd;background:#33363c;}")

        root = QVBoxLayout(self)
        title = QLabel("이브이가 진화할 준비가 됐어요!")
        title.setObjectName("title")
        sub = QLabel("8종 중 하나를 골라줘 — 고른 진화형으로 자라납니다.")
        sub.setObjectName("sub")
        root.addWidget(title)
        root.addWidget(sub)

        grid = QGridLayout()
        grid.setSpacing(10)
        root.addLayout(grid)
        for i, slug in enumerate(petmeta.EEVEELUTION_SLUGS):
            btn = QPushButton(korean_name(slug))
            icon = self._thumb(slug)
            if icon is not None:
                btn.setIcon(icon)
                btn.setIconSize(QSize(72, 72))
            btn.clicked.connect(lambda _=False, s=slug: self._pick(s))
            grid.addWidget(btn, i // 4, i % 4)

    def _thumb(self, slug):
        try:
            sheet = SpriteSheet(slug, resources.pet_dir(slug))
            frames = sheet.animation("idle").frames
            if frames:
                return QIcon(frames[0])
        except Exception:  # noqa: BLE001
            pass
        return None

    def _pick(self, slug):
        self.chosen = slug
        self.accept()
