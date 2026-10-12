import subprocess

import pytest


def _video(path, audio: bool):
    inputs = ["-f", "lavfi", "-i", "color=c=gray:s=64x36:d=1:r=10"]
    if audio:
        inputs += ["-f", "lavfi", "-i", "sine=frequency=440:duration=1"]
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", *inputs, "-shortest", "-c:v", "libx264",
                    "-pix_fmt", "yuv420p", *(["-c:a", "aac"] if audio else []), str(path)], check=True)
    return path


@pytest.fixture
def video_with_audio(tmp_path):
    return _video(tmp_path / "with_audio.mp4", True)


@pytest.fixture
def video_without_audio(tmp_path):
    return _video(tmp_path / "silent.mp4", False)
