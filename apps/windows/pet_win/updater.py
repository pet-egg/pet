"""윈도우용 커스텀 인앱 업데이터 (맥 Sparkle 에 대응).

맥 앱은 Sparkle 로 자동 업데이트한다. 윈도우는 Sparkle 이 없어 같은 개념을 직접
구현한다 — **같은 EdDSA(Ed25519) 키로 서명 검증**하고, GitHub 릴리스에 올라온
`windows-appcast.json`(버전·exe URL·서명)을 읽어 새 버전이면 내려받아 검증한 뒤,
사용자가 트레이 메뉴에서 누르면 실행 중인 exe 를 교체하고 재실행한다.

Sparkle UX 를 그대로 맞춘다: **조용히 확인 → 팝업 없이 메뉴로만 알림 → 사용자가
눌러야 설치.** 미서명 배포라 서명 검증이 무결성의 유일한 담보다.

frozen(.exe) + Windows 에서만 활성. dev/소스 실행·맥에서는 아무 것도 안 한다.

윈도우 자가 교체의 제약: 실행 중인 exe 는 덮어쓸 수 없지만 **rename 은 된다**. 그래서
현재 exe 를 pet.old.exe 로 옮기고(rename) 새 exe 를 제자리에 놓은 뒤 재실행하며,
남은 pet.old.exe 는 다음 시작 때 지운다.
"""
from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import threading
import urllib.request

from PySide6.QtCore import QObject, Signal

from ._version import __version__

# Sparkle 과 **같은** EdDSA(Ed25519) 공개키 — 맥 Info.plist 의 SUPublicEDKey 와 동일.
# 짝이 되는 개인키(CI Secret SPARKLE_EDDSA_PRIVATE_KEY)로 pet.exe 를 서명한다.
PUBLIC_KEY_B64 = "5zPY3WaXtB6g72hVacYErOpHAnHYAbCcwVGWjK1p8R4="

# 최신 릴리스에 올라온 윈도우 업데이트 매니페스트. `--latest` 릴리스가 이 태그이므로
# /latest/ 로 항상 최신 매니페스트가 해결된다(그 안의 url 은 태그 고정 exe 를 가리킴).
MANIFEST_URL = "https://github.com/pet-egg/pet/releases/latest/download/windows-appcast.json"

_NET_TIMEOUT = 15


def is_supported() -> bool:
    """업데이터가 실제로 동작하는 환경인지 — frozen .exe + Windows 에서만."""
    return sys.platform == "win32" and bool(getattr(sys, "frozen", False))


def parse_version(s: str):
    """'1.2.3' → (1,2,3). 숫자가 아니면 그 자리 0. 비교용 튜플."""
    parts = []
    for chunk in str(s or "").strip().lstrip("vV").split("."):
        num = ""
        for ch in chunk:
            if ch.isdigit():
                num += ch
            else:
                break
        parts.append(int(num) if num else 0)
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts[:3])


def is_newer(remote: str, local: str) -> bool:
    return parse_version(remote) > parse_version(local)


def verify_signature(data: bytes, sig_b64: str) -> bool:
    """pet.exe 바이트를 임베드된 Ed25519 공개키로 검증."""
    try:
        from nacl.signing import VerifyKey
        from nacl.exceptions import BadSignatureError
    except Exception:  # noqa: BLE001 — nacl 미탑재면 안전하게 실패
        return False
    try:
        vk = VerifyKey(base64.b64decode(PUBLIC_KEY_B64))
        vk.verify(data, base64.b64decode(sig_b64))
        return True
    except (BadSignatureError, ValueError, TypeError):
        return False


def _exe_dir() -> str:
    return os.path.dirname(os.path.abspath(sys.executable))


def _old_exe_path() -> str:
    return os.path.join(_exe_dir(), "pet.old.exe")


def _staged_exe_path() -> str:
    return os.path.join(_exe_dir(), "pet.new.exe")


def cleanup_old():
    """이전 업데이트가 남긴 pet.old.exe 를 지운다(시작 시 호출). 실패는 무시."""
    for p in (_old_exe_path(), _staged_exe_path()):
        try:
            if os.path.isfile(p):
                os.remove(p)
        except OSError:
            pass


class Updater(QObject):
    """백그라운드로 확인·다운로드·검증하고, 준비되면 신호를 낸다.

    updateAvailable(version): 새 버전 검증 완료 → 메뉴에 "설치" 노출.
    checkFinished(found, message): 수동 확인 결과 피드백용(트레이 풍선).
    """
    updateAvailable = Signal(str)
    checkFinished = Signal(bool, str)

    def __init__(self, current_version: str = __version__, parent=None):
        super().__init__(parent)
        self.current_version = current_version
        self.staged_version: str | None = None   # 검증까지 끝난 대기 버전
        self._staged_path: str | None = None
        self._busy = False

    # ── 확인 ────────────────────────────────────────────────────
    def check_async(self, silent: bool = True):
        if self._busy or not is_supported():
            return
        self._busy = True
        threading.Thread(target=self._check, args=(silent,), daemon=True).start()

    def _check(self, silent: bool):
        try:
            manifest = self._fetch_manifest()
            remote = manifest.get("version", "")
            if not remote or not is_newer(remote, self.current_version):
                self.checkFinished.emit(False, "최신 버전입니다.")
                return
            # 이미 이 버전을 받아 뒀으면 재다운로드 생략.
            if self.staged_version == remote and self._staged_path and os.path.isfile(self._staged_path):
                self.updateAvailable.emit(remote)
                return
            data = self._download(manifest["url"])
            if not verify_signature(data, manifest.get("edSignature", "")):
                self.checkFinished.emit(False, "업데이트 서명 검증에 실패해 설치하지 않았습니다.")
                return
            path = _staged_exe_path()
            with open(path, "wb") as f:
                f.write(data)
            self.staged_version = remote
            self._staged_path = path
            self.updateAvailable.emit(remote)
        except Exception as e:  # noqa: BLE001 — 네트워크/파싱 실패는 조용히(수동이면 피드백)
            self.checkFinished.emit(False, f"업데이트 확인 실패: {e}")
        finally:
            self._busy = False

    def _fetch_manifest(self) -> dict:
        req = urllib.request.Request(MANIFEST_URL, headers={"User-Agent": "pet-updater"})
        with urllib.request.urlopen(req, timeout=_NET_TIMEOUT) as r:
            return json.loads(r.read().decode("utf-8"))

    def _download(self, url: str) -> bytes:
        req = urllib.request.Request(url, headers={"User-Agent": "pet-updater"})
        with urllib.request.urlopen(req, timeout=_NET_TIMEOUT * 4) as r:
            return r.read()

    # ── 적용 ────────────────────────────────────────────────────
    def has_staged(self) -> bool:
        return bool(self.staged_version and self._staged_path and os.path.isfile(self._staged_path))

    def apply_and_restart(self) -> bool:
        """실행 중 exe 를 rename 으로 비켜 두고 새 exe 를 제자리에 놓은 뒤 재실행.

        성공 시 새 프로세스를 띄우고 True 를 돌려준다(호출부가 앱 종료).
        """
        if not (is_supported() and self.has_staged()):
            return False
        cur = os.path.abspath(sys.executable)
        old = _old_exe_path()
        staged = self._staged_path
        try:
            if os.path.isfile(old):
                os.remove(old)
        except OSError:
            pass
        try:
            os.replace(cur, old)        # 실행 중 exe 를 옆으로(윈도우는 rename 허용)
            os.replace(staged, cur)     # 새 exe 를 제자리에
        except OSError:
            # 롤백: 새 exe 를 못 놓았으면 원상복구 시도.
            try:
                if not os.path.isfile(cur) and os.path.isfile(old):
                    os.replace(old, cur)
            except OSError:
                pass
            return False
        try:
            subprocess.Popen([cur], close_fds=True)
        except OSError:
            return False
        self.staged_version = None
        self._staged_path = None
        return True
