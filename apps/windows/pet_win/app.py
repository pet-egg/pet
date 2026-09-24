"""윈도우용 데스크톱 펫 앱 (PySide6).

투명·항상 위·테두리 없는 창에 펫 스프라이트를 그리고, 시스템 트레이 메뉴에서
펫을 고른다. Claude Code 상태(~/.claude)를 250ms 폴링해 달리기/얼음/헤롱헤롱/실패/
잠듦을 표시하고, 트랜스크립트 토큰으로 경험치·진화를 계산한다.

macOS 앱(ConnorPet)과 리소스(pets/)·로직(상태 워처·XP 모델)을 공유하는 크로스플랫폼
포트다. AppKit 대신 Qt 로 UI 만 다시 그렸다.
"""
from __future__ import annotations

import os
import sys

from PySide6.QtCore import Qt, QTimer, QPoint, QRectF
from PySide6.QtGui import (QAction, QActionGroup, QColor, QCursor, QIcon,
                           QPainter, QPen, QPixmap)
from PySide6.QtWidgets import (QApplication, QMenu, QSystemTrayIcon, QWidget)

from . import animation as anim
from . import petmeta
from . import resources
from . import xpmodel
from .spritesheet import SpriteSheet
from .status_watcher import ClaudeCodeStatusWatcher

POLL_MS = 250
SCALE = 0.7                 # 200px 프레임을 이만큼 축소해 표시
XP_BAR_H = 6
PAD = 8                     # 창 여백(그림자/여유)
SETTINGS_ORG = "pet-egg"
SETTINGS_APP = "pet"


class PetWindow(QWidget):
    def __init__(self):
        super().__init__(None)
        self.setWindowFlags(
            Qt.FramelessWindowHint
            | Qt.WindowStaysOnTopHint
            | Qt.Tool                    # 작업표시줄에 안 뜨게
            | Qt.NoDropShadowWindowHint
        )
        self.setAttribute(Qt.WA_TranslucentBackground, True)
        self.setAttribute(Qt.WA_ShowWithoutActivating, True)
        self.setMouseTracking(True)

        from PySide6.QtCore import QSettings
        self.settings = QSettings(SETTINGS_ORG, SETTINGS_APP)

        # ── 상태 ────────────────────────────────────────────────
        self.base_slug = self.settings.value("selectedPetSlug", "totodile")
        if self.base_slug not in petmeta.AVAILABLE_PET_SLUGS:
            self.base_slug = petmeta.AVAILABLE_PET_SLUGS[0]
        self.evolution_enabled = self.settings.value(
            "evolutionEnabled", False, type=bool)
        self.bar_always = self.settings.value("barAlwaysVisible", False, type=bool)
        self.pet_tokens = self._load_tokens()

        self.watcher = ClaudeCodeStatusWatcher()
        self.sheet_cache = {}
        self.current_display_slug = ""
        self.sheet: SpriteSheet | None = None
        self.current_anim_name = anim.IDLE
        self.current_anim = None
        self.frame_index = 0
        self._hovering = False
        self._drag_offset = None

        # 프레임 타이머는 _load_display_pet 이 _schedule_frame 을 부르기 전에 있어야 한다.
        self.frame_timer = QTimer(self)
        self.frame_timer.setSingleShot(True)
        self.frame_timer.timeout.connect(self._advance_frame)

        self._load_display_pet()
        self._place_default_position()
        self._schedule_frame()

        # ── 타이머 ──────────────────────────────────────────────
        self.poll_timer = QTimer(self)
        self.poll_timer.timeout.connect(self._poll)
        self.poll_timer.start(POLL_MS)

        self.save_timer = QTimer(self)
        self.save_timer.timeout.connect(self._save_tokens)
        self.save_timer.start(10_000)

    # ── 경험치 지속성 ───────────────────────────────────────────
    def _load_tokens(self):
        out = {}
        self.settings.beginGroup("petTokens")
        for key in self.settings.childKeys():
            try:
                out[key] = float(self.settings.value(key, 0.0))
            except (TypeError, ValueError):
                pass
        self.settings.endGroup()
        return out

    def _save_tokens(self):
        self.settings.beginGroup("petTokens")
        for slug, val in self.pet_tokens.items():
            self.settings.setValue(slug, float(val))
        self.settings.endGroup()
        self.settings.sync()

    # ── 스프라이트 로딩 ─────────────────────────────────────────
    def _cached_sheet(self, slug):
        if slug in self.sheet_cache:
            return self.sheet_cache[slug]
        sheet = SpriteSheet(slug, resources.pet_dir(slug))
        self.sheet_cache[slug] = sheet
        return sheet

    def _current_stage(self):
        if not self.evolution_enabled:
            return 0
        return xpmodel.stage(self.pet_tokens.get(self.base_slug, 0.0))

    def _load_display_pet(self):
        """base_slug + 진화단계로 실제 표시 슬러그를 정하고 시트를 로드."""
        stage = self._current_stage()
        slug = petmeta.display_slug(self.base_slug, stage)
        if slug == self.current_display_slug and self.sheet is not None:
            return
        try:
            self.sheet = self._cached_sheet(slug)
        except Exception as e:  # noqa: BLE001 — 리소스 문제는 콘솔에 남기고 넘어감
            sys.stderr.write(f"[pet] 시트 로드 실패 {slug}: {e}\n")
            return
        self.current_display_slug = slug
        self._resize_to_frame()
        self._set_animation(self.current_anim_name, force=True)

    def _resize_to_frame(self):
        w = int(self.sheet.frame_w * SCALE) + PAD * 2
        h = int(self.sheet.frame_h * SCALE) + PAD * 2 + XP_BAR_H + 4
        self.resize(w, h)

    def _set_animation(self, name, force=False):
        if not self.sheet:
            return
        if name == self.current_anim_name and not force and self.current_anim:
            return
        self.current_anim_name = name
        self.current_anim = self.sheet.animation(name)
        self.frame_index = 0
        self.update()
        self._schedule_frame()

    # ── 애니메이션 재생 ─────────────────────────────────────────
    def _schedule_frame(self):
        if not self.current_anim or not self.current_anim.durations_ms:
            return
        dur = self.current_anim.durations_ms[
            self.frame_index % len(self.current_anim.durations_ms)]
        self.frame_timer.start(max(16, int(dur)))

    def _advance_frame(self):
        if not self.current_anim:
            return
        self.frame_index = (self.frame_index + 1) % len(self.current_anim.frames)
        self.update()
        self._schedule_frame()

    # ── 상태 폴링 ──────────────────────────────────────────────
    def _poll(self):
        result = self.watcher.poll()
        if result.gained_tokens > 0:
            self.pet_tokens[self.base_slug] = (
                self.pet_tokens.get(self.base_slug, 0.0) + result.gained_tokens)
            if self.evolution_enabled:
                self._load_display_pet()  # 단계가 올랐으면 진화형으로 교체
        self._set_animation(result.animation)
        if self.bar_always or self._hovering:
            self.update()

    # ── 그리기 ─────────────────────────────────────────────────
    def paintEvent(self, event):
        p = QPainter(self)
        p.setRenderHint(QPainter.SmoothPixmapTransform, True)
        if self.current_anim and self.current_anim.frames:
            pm = self.current_anim.frames[
                self.frame_index % len(self.current_anim.frames)]
            tw = int(self.sheet.frame_w * SCALE)
            th = int(self.sheet.frame_h * SCALE)
            scaled = pm.scaled(tw, th, Qt.KeepAspectRatio,
                               Qt.SmoothTransformation)
            p.drawPixmap(PAD, PAD, scaled)

        if self.bar_always or self._hovering:
            self._draw_xp_bar(p)
        p.end()

    def _draw_xp_bar(self, p):
        prog = xpmodel.progress(self.pet_tokens.get(self.base_slug, 0.0))
        w = self.width() - PAD * 2
        y = self.height() - XP_BAR_H - 2
        track = QRectF(PAD, y, w, XP_BAR_H)
        p.setPen(Qt.NoPen)
        p.setBrush(QColor(0, 0, 0, 90))
        p.drawRoundedRect(track, XP_BAR_H / 2, XP_BAR_H / 2)
        fill_w = max(0.0, min(1.0, prog.percent)) * w
        if fill_w > 0:
            fill = QRectF(PAD, y, fill_w, XP_BAR_H)
            p.setBrush(QColor(120, 200, 120, 220))
            p.drawRoundedRect(fill, XP_BAR_H / 2, XP_BAR_H / 2)

    # ── 마우스 ─────────────────────────────────────────────────
    def enterEvent(self, event):
        self._hovering = True
        self.watcher.acknowledge_done()   # 헤롱헤롱 확인
        self.update()

    def leaveEvent(self, event):
        self._hovering = False
        self.update()

    def mousePressEvent(self, event):
        if event.button() == Qt.LeftButton:
            self._drag_offset = event.globalPosition().toPoint() - self.frameGeometry().topLeft()
            event.accept()

    def mouseMoveEvent(self, event):
        if self._drag_offset is not None and (event.buttons() & Qt.LeftButton):
            self.move(event.globalPosition().toPoint() - self._drag_offset)
            event.accept()

    def mouseReleaseEvent(self, event):
        self._drag_offset = None
        self._save_position()

    def contextMenuEvent(self, event):
        self._build_menu().exec(event.globalPos())

    # ── 창 위치 지속성 ──────────────────────────────────────────
    def _place_default_position(self):
        pos = self.settings.value("windowPos")
        if isinstance(pos, QPoint):
            self.move(pos)
            return
        screen = QApplication.primaryScreen().availableGeometry()
        self.move(screen.right() - self.width() - 40,
                  screen.bottom() - self.height() - 60)

    def _save_position(self):
        self.settings.setValue("windowPos", self.frameGeometry().topLeft())

    # ── 메뉴 ───────────────────────────────────────────────────
    def _build_menu(self):
        menu = QMenu(self)

        pet_menu = menu.addMenu("펫 선택")
        group = QActionGroup(self)
        group.setExclusive(True)
        for slug in petmeta.AVAILABLE_PET_SLUGS:
            try:
                name = self._cached_sheet(slug).display_name
            except Exception:  # noqa: BLE001
                name = slug
            act = QAction(name, self, checkable=True)
            act.setChecked(slug == self.base_slug)
            act.triggered.connect(lambda _=False, s=slug: self.change_pet(s))
            group.addAction(act)
            pet_menu.addAction(act)

        menu.addSeparator()
        evo = QAction("진화 사용", self, checkable=True)
        evo.setChecked(self.evolution_enabled)
        evo.triggered.connect(self.toggle_evolution)
        menu.addAction(evo)

        bar = QAction("경험치 바 항상 표시", self, checkable=True)
        bar.setChecked(self.bar_always)
        bar.triggered.connect(self.toggle_bar)
        menu.addAction(bar)

        reset = QAction("이 펫 경험치 초기화", self)
        reset.triggered.connect(self.reset_xp)
        menu.addAction(reset)

        menu.addSeparator()
        quit_act = QAction("종료", self)
        quit_act.triggered.connect(QApplication.instance().quit)
        menu.addAction(quit_act)
        return menu

    # ── 메뉴 동작 ──────────────────────────────────────────────
    def change_pet(self, slug):
        self.base_slug = slug
        self.settings.setValue("selectedPetSlug", slug)
        self._load_display_pet()

    def toggle_evolution(self, checked):
        self.evolution_enabled = checked
        self.settings.setValue("evolutionEnabled", checked)
        self._load_display_pet()

    def toggle_bar(self, checked):
        self.bar_always = checked
        self.settings.setValue("barAlwaysVisible", checked)
        self.update()

    def reset_xp(self):
        self.pet_tokens[self.base_slug] = 0.0
        self._save_tokens()
        self._load_display_pet()
        self.update()

    def tray_icon(self) -> QIcon:
        """트레이 아이콘 = 현재 펫의 idle 첫 프레임."""
        if self.sheet:
            idle = self.sheet.animation(anim.IDLE)
            if idle.frames:
                return QIcon(idle.frames[0])
        return QIcon()


def _load_app_icon() -> QIcon:
    here = os.path.dirname(os.path.abspath(__file__))
    for cand in [
        os.path.join(getattr(sys, "_MEIPASS", ""), "app-icon.png"),
        os.path.join(os.path.dirname(here), "app-icon.png"),
        os.path.join(os.path.dirname(os.path.dirname(here)), "assets", "app-icon.png"),
    ]:
        if cand and os.path.isfile(cand):
            pm = QPixmap(cand)
            if not pm.isNull():
                return QIcon(pm)
    return QIcon()


def main():
    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)   # 창을 닫아도(안 닫지만) 트레이로 상주

    win = PetWindow()
    win.show()

    tray_icon = _load_app_icon()
    if tray_icon.isNull():
        tray_icon = win.tray_icon()
    tray = QSystemTrayIcon(tray_icon, app)
    tray.setToolTip("pet — 데스크톱 펫")
    tray.setContextMenu(win._build_menu())
    tray.activated.connect(lambda reason: win.raise_())
    tray.show()
    # 트레이 참조 유지(GC 방지).
    win._tray = tray

    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
