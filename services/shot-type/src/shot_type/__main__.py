from __future__ import annotations

from cutsheet_common.bus import KafkaBus
from cutsheet_common.logs import setup_logging
from cutsheet_common.storage import Storage

from .config import Settings
from .detect import MediaPipeDetector
from .service import SERVICE, ShotTypeService


def main() -> None:
    setup_logging(SERVICE)
    settings = Settings.from_env()
    service = ShotTypeService(Storage(), settings, MediaPipeDetector(settings))
    KafkaBus(SERVICE).run(["scene.ready-for-enrichment"], service.handle)


if __name__ == "__main__":
    main()
