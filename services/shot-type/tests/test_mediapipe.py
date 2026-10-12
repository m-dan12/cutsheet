"""Настоящие модели MediaPipe на тестовых снимках MediaPipe. Нужна сеть (storage.googleapis.com):
запускается при ST_TEST_MODELS=1 (в CI включено), иначе пропускается."""

import os
import urllib.request
from pathlib import Path

import pytest

pytestmark = pytest.mark.skipif(os.environ.get("ST_TEST_MODELS") != "1", reason="ST_TEST_MODELS != 1")

ASSETS = "https://storage.googleapis.com/mediapipe-assets"
CACHE = Path(os.environ.get("ST_TEST_CACHE", Path.home() / ".cache" / "cutsheet" / "mediapipe-test"))


def asset(name: str) -> bytes:
    path = CACHE / name
    if not path.is_file():
        CACHE.mkdir(parents=True, exist_ok=True)
        urllib.request.urlretrieve(f"{ASSETS}/{name}", path)
    return path.read_bytes()


@pytest.fixture(scope="module")
def detector():
    from shot_type.config import Settings
    from shot_type.detect import MediaPipeDetector

    d = MediaPipeDetector(Settings(model_dir=str(CACHE / "models")))
    yield d
    d.close()


@pytest.mark.parametrize("name, expected", [
    ("pose.jpg", "wide"),          # человек во весь рост на пляже
    ("portrait.jpg", "medium"),    # по пояс
    ("burger.jpg", "detail"),      # предмет, людей нет
])
def test_real_frames(detector, name, expected):
    from shot_type.classify import classify_frame
    from shot_type.detect import load_rgb

    assert classify_frame(detector.observe(load_rgb(asset(name), 960))).shot_type == expected
