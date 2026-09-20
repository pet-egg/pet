"""스프라이트 시트 로더 (SpriteSheet.swift / PetManifest.swift 포팅).

pet.json 매니페스트 + spritesheet.png 를 읽어 애니메이션별 프레임(QPixmap)과
프레임 지속시간(ms)을 뽑는다. 프레임은 `col*width, row*height` 에서 잘라낸다.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass
from typing import Optional

from PySide6.QtGui import QPixmap


@dataclass
class Animation:
    name: str
    frames: list          # list[QPixmap]
    durations_ms: list    # list[float]


class SpriteSheet:
    def __init__(self, slug: str, pet_dir: str):
        self.slug = slug
        manifest_path = os.path.join(pet_dir, "pet.json")
        with open(manifest_path, "r", encoding="utf-8") as f:
            self.manifest = json.load(f)

        frame = self.manifest.get("frame", {})
        self.frame_w = int(frame.get("width", 200))
        self.frame_h = int(frame.get("height", 200))
        self.fps = float(self.manifest.get("fps", 6)) or 6.0
        self.display_name = self.manifest.get("displayName", slug)
        self.default_animation = self.manifest.get("defaultAnimation", "idle")

        sheet_name = self.manifest.get("spritesheetPath", "spritesheet.png")
        self._sheet = QPixmap(os.path.join(pet_dir, sheet_name))
        if self._sheet.isNull():
            raise RuntimeError(f"스프라이트 시트를 못 읽음: {slug}/{sheet_name}")

        self._animations = {}
        for name, spec in (self.manifest.get("animations") or {}).items():
            self._animations[name] = self._build_animation(name, spec)

    def _build_animation(self, name, spec) -> Animation:
        row = int(spec.get("row", 0))
        count = int(spec.get("frames", 1))
        durations = spec.get("frameDurationsMs")
        if not isinstance(durations, list) or len(durations) != count:
            durations = [1000.0 / self.fps] * count
        frames = []
        for col in range(count):
            x = col * self.frame_w
            y = row * self.frame_h
            frames.append(self._sheet.copy(x, y, self.frame_w, self.frame_h))
        return Animation(name=name, frames=frames,
                         durations_ms=[float(d) for d in durations])

    def animation(self, name: str) -> Animation:
        """이름으로 애니메이션을 찾되, 없으면 기본 애니메이션으로 폴백."""
        if name in self._animations:
            return self._animations[name]
        if self.default_animation in self._animations:
            return self._animations[self.default_animation]
        # 그래도 없으면 아무거나 첫 번째.
        return next(iter(self._animations.values()))

    def has_animation(self, name: str) -> bool:
        return name in self._animations
