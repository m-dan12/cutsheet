import importlib.util
from pathlib import Path

import pytest

_TOOL = Path(__file__).resolve().parents[3] / "tools" / "make_sample_script.py"
_spec = importlib.util.spec_from_file_location("make_sample_script", _TOOL)
sample = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sample)


@pytest.fixture
def sample_docx(tmp_path):
    return sample.build(tmp_path / "script.docx")
