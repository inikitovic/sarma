"""Structured JSON + console logging for Sarma Launcher."""

from __future__ import annotations

import json
import logging
import os
import sys
from datetime import datetime, timezone
from logging.handlers import RotatingFileHandler

from sarma.config import cfg


class FlushStreamHandler(logging.StreamHandler):
    """StreamHandler that flushes after every emit (fixes conda run buffering)."""

    def emit(self, record: logging.LogRecord) -> None:
        super().emit(record)
        self.flush()


class JsonFormatter(logging.Formatter):
    """Emit log records as single-line JSON."""

    def format(self, record: logging.LogRecord) -> str:
        entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "worker_id": getattr(record, "worker_id", cfg.WORKER_ID),
            "task_id": getattr(record, "task_id", None),
            "event": record.getMessage(),
        }
        # Include extra fields if supplied
        for key in ("duration", "status", "exit_code"):
            val = getattr(record, key, None)
            if val is not None:
                entry[key] = val
        return json.dumps(entry)


def get_logger(name: str = "sarma") -> logging.Logger:
    """Create a logger with JSON file handler and human-readable console handler."""
    logger = logging.getLogger(name)
    if logger.handlers:
        return logger  # already configured

    logger.setLevel(logging.DEBUG)

    # Console handler — human-readable, flushes immediately
    console = FlushStreamHandler(sys.stderr)
    console.setLevel(logging.INFO)
    console.setFormatter(
        logging.Formatter("[%(asctime)s] %(levelname)-7s %(message)s", datefmt="%H:%M:%S")
    )
    logger.addHandler(console)

    # File handler — JSON structured, rotated at 10 MB
    os.makedirs(cfg.LOG_DIR, exist_ok=True)
    log_file = os.path.join(cfg.LOG_DIR, f"{cfg.WORKER_ID}.jsonl")
    file_handler = RotatingFileHandler(log_file, maxBytes=10 * 1024 * 1024, backupCount=5)
    file_handler.setLevel(logging.DEBUG)
    file_handler.setFormatter(JsonFormatter())
    logger.addHandler(file_handler)

    return logger
