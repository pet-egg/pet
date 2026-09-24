"""업데이터 순수 로직 테스트 — 버전 비교, Ed25519 서명 검증, 안전 가드.

실제 exe 교체(rename-in-place)는 Windows+frozen 전용이라 여기선 검증하지 않고,
지원 환경 가드(is_supported/apply_and_restart)만 확인한다.
"""
import base64
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from pet_win import updater  # noqa: E402


# ── 버전 파싱/비교 ─────────────────────────────────────────────
def test_parse_version():
    assert updater.parse_version("1.2.3") == (1, 2, 3)
    assert updater.parse_version("v0.1.0") == (0, 1, 0)
    assert updater.parse_version("2.0") == (2, 0, 0)
    assert updater.parse_version("") == (0, 0, 0)
    assert updater.parse_version("1.2.3-beta") == (1, 2, 3)


def test_is_newer():
    assert updater.is_newer("1.2.4", "1.2.3")
    assert updater.is_newer("1.3.0", "1.2.9")
    assert updater.is_newer("2.0.0", "1.9.9")
    assert not updater.is_newer("1.2.3", "1.2.3")
    assert not updater.is_newer("1.2.2", "1.2.3")
    assert updater.is_newer("0.1.0", "0.0.0")   # dev(0.0.0) → 항상 업데이트 있음


# ── Ed25519 서명 검증 ──────────────────────────────────────────
def test_verify_signature_roundtrip(monkeypatch):
    from nacl.signing import SigningKey
    sk = SigningKey.generate()
    pub_b64 = base64.b64encode(bytes(sk.verify_key)).decode()
    monkeypatch.setattr(updater, "PUBLIC_KEY_B64", pub_b64)

    data = b"pretend this is pet.exe bytes " * 100
    sig_b64 = base64.b64encode(sk.sign(data).signature).decode()
    assert updater.verify_signature(data, sig_b64) is True

    # 데이터 변조 → 실패
    assert updater.verify_signature(data + b"x", sig_b64) is False
    # 서명 변조 → 실패
    bad = base64.b64encode(b"\x00" * 64).decode()
    assert updater.verify_signature(data, bad) is False


def test_verify_signature_rejects_garbage():
    assert updater.verify_signature(b"abc", "not-base64!!") is False
    assert updater.verify_signature(b"abc", "") is False


# ── 지원 환경 가드 ─────────────────────────────────────────────
def test_not_supported_off_windows():
    # mac/리눅스 또는 비-frozen 에서는 비활성(안전).
    if sys.platform != "win32" or not getattr(sys, "frozen", False):
        assert updater.is_supported() is False


def test_apply_noops_when_unsupported():
    u = updater.Updater(current_version="1.0.0")
    # staged 없음 + 미지원 → False(아무 것도 안 함)
    assert u.apply_and_restart() is False
    assert u.has_staged() is False


def test_check_async_noop_when_unsupported():
    u = updater.Updater(current_version="1.0.0")
    # 미지원 환경에선 스레드조차 안 띄운다(예외 없이 조용히).
    u.check_async(silent=True)
    assert u.staged_version is None


if __name__ == "__main__":
    import pytest
    raise SystemExit(pytest.main([__file__, "-v"]))
