"""Помощники для тестов сервисов: S3 в локальной папке вместо MinIO."""

from __future__ import annotations

import shutil
from pathlib import Path

from .storage import parse_s3_uri, s3_uri


class FakeStorage:
    """s3://bucket/key -> root/bucket/key. Интерфейс как у cutsheet_common.storage.Storage."""

    def __init__(self, root: str | Path):
        self.root = Path(root)

    def path(self, uri_or_bucket: str, key: str | None = None) -> Path:
        bucket, key = parse_s3_uri(uri_or_bucket) if key is None else (uri_or_bucket, key)
        p = self.root / bucket / key
        p.parent.mkdir(parents=True, exist_ok=True)
        return p

    def ensure_bucket(self, bucket: str) -> None:
        (self.root / bucket).mkdir(parents=True, exist_ok=True)

    def download(self, uri: str, dest: str | Path) -> Path:
        Path(dest).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(self.path(uri), dest)
        return Path(dest)

    def upload_file(self, src: str | Path, bucket: str, key: str, content_type: str | None = None) -> str:
        shutil.copy(src, self.path(bucket, key))
        return s3_uri(bucket, key)

    def put_bytes(self, data: bytes, bucket: str, key: str, content_type: str | None = None) -> str:
        self.path(bucket, key).write_bytes(data)
        return s3_uri(bucket, key)

    def get_bytes(self, uri: str) -> bytes:
        return self.path(uri).read_bytes()

    def exists(self, uri: str) -> bool:
        bucket, key = parse_s3_uri(uri)
        return (self.root / bucket / key).is_file()
