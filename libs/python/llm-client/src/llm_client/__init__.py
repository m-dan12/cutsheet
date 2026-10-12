"""Общий слой доступа к LLM (ТЗ 5.10)."""

from .client import LLMClient, LLMError, LLMInvalidOutput, image_part
from .config import LLMConfig

__all__ = ["LLMClient", "LLMConfig", "LLMError", "LLMInvalidOutput", "image_part"]
