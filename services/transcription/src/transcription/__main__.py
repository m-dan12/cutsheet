from __future__ import annotations

from cutsheet_common.bus import KafkaBus
from cutsheet_common.logs import setup_logging
from cutsheet_common.storage import Storage

from .config import Settings
from .service import SERVICE, TranscriptionService
from .transcribe import make_transcriber


def main() -> None:
    setup_logging(SERVICE)
    s = Settings.from_env()
    storage = Storage()
    storage.ensure_bucket(s.bucket)
    service = TranscriptionService(storage, s, make_transcriber(s.backend, s.model, s.device, s.compute_type))
    KafkaBus(SERVICE).run(["video.uploaded", "script.parsed"], service.handle)


if __name__ == "__main__":
    main()
