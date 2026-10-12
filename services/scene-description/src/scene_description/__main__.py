from __future__ import annotations

from cutsheet_common.bus import KafkaBus
from cutsheet_common.logs import setup_logging
from cutsheet_common.storage import Storage
from llm_client import LLMClient

from .config import Settings
from .service import SERVICE, SceneDescriptionService


def main() -> None:
    setup_logging(SERVICE)
    settings = Settings.from_env()
    storage = Storage()
    storage.ensure_bucket(settings.bucket)
    llm = LLMClient() if settings.mode == "llm" else None
    service = SceneDescriptionService(storage, settings, llm)
    KafkaBus(SERVICE).run(["script.parsed", "scene.ready-for-enrichment"], service.handle)


if __name__ == "__main__":
    main()
