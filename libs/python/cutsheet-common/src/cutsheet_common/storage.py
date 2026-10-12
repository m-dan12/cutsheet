"""Работа с S3-совместимым хранилищем (MinIO)."""

from __future__ import annotations

import os
from pathlib import Path

import boto3
from botocore.client import Config
from botocore.exceptions import ClientError


def parse_s3_uri(uri: str) -> tuple[str, str]:
    if not uri.startswith("s3://"):
        raise ValueError(f"not an s3 uri: {uri}")
    bucket, _, key = uri[5:].partition("/")
    if not bucket or not key:
        raise ValueError(f"bad s3 uri: {uri}")
    return bucket, key


def s3_uri(bucket: str, key: str) -> str:
    return f"s3://{bucket}/{key}"


class Storage:
    def __init__(self, endpoint: str | None = None, access_key: str | None = None,
                 secret_key: str | None = None, region: str | None = None):
        self.client = boto3.client(
            "s3",
            endpoint_url=endpoint or os.environ.get("S3_ENDPOINT"),
            aws_access_key_id=access_key or os.environ.get("S3_ACCESS_KEY"),
            aws_secret_access_key=secret_key or os.environ.get("S3_SECRET_KEY"),
            region_name=region or os.environ.get("S3_REGION", "us-east-1"),
            config=Config(signature_version="s3v4", s3={"addressing_style": "path"}),
        )

    def ensure_bucket(self, bucket: str) -> None:
        try:
            self.client.head_bucket(Bucket=bucket)
        except ClientError:
            self.client.create_bucket(Bucket=bucket)

    def download(self, uri: str, dest: str | Path) -> Path:
        bucket, key = parse_s3_uri(uri)
        dest = Path(dest)
        dest.parent.mkdir(parents=True, exist_ok=True)
        self.client.download_file(bucket, key, str(dest))
        return dest

    def upload_file(self, src: str | Path, bucket: str, key: str, content_type: str | None = None) -> str:
        extra = {"ContentType": content_type} if content_type else None
        self.client.upload_file(str(src), bucket, key, ExtraArgs=extra)
        return s3_uri(bucket, key)

    def put_bytes(self, data: bytes, bucket: str, key: str, content_type: str | None = None) -> str:
        kwargs = {"ContentType": content_type} if content_type else {}
        self.client.put_object(Bucket=bucket, Key=key, Body=data, **kwargs)
        return s3_uri(bucket, key)

    def get_bytes(self, uri: str) -> bytes:
        bucket, key = parse_s3_uri(uri)
        return self.client.get_object(Bucket=bucket, Key=key)["Body"].read()

    def exists(self, uri: str) -> bool:
        bucket, key = parse_s3_uri(uri)
        try:
            self.client.head_object(Bucket=bucket, Key=key)
            return True
        except ClientError as e:
            if e.response.get("Error", {}).get("Code") in ("404", "NoSuchKey", "NotFound"):
                return False
            raise
