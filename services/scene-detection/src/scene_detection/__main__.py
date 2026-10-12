from __future__ import annotations

from cutsheet_common.bus import KafkaBus
from cutsheet_common.logs import setup_logging
from cutsheet_common.storage import Storage

from .config import Settings
from .service import SERVICE, SceneDetectionService


def main() -> None:
    setup_logging(SERVICE)
    settings = Settings.from_env()
    storage = Storage()
    storage.ensure_bucket(settings.bucket)
    service = SceneDetectionService(storage, settings)
    KafkaBus(SERVICE).run(["video.uploaded"], service.handle)


if __name__ == "__main__":
    main()
