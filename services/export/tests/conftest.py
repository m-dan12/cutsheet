import copy
import json
from pathlib import Path

import pytest

EXAMPLE = Path(__file__).resolve().parents[3] / "contracts" / "examples" / "documents" / "sheet-snapshot.v1.json"


@pytest.fixture
def snapshot():
    return copy.deepcopy(json.loads(EXAMPLE.read_text(encoding="utf-8")))
