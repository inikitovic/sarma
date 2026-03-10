"""Task schema for the Sarma Launcher."""

from __future__ import annotations

import json
import uuid
from datetime import datetime, timezone
from typing import Optional

from pydantic import BaseModel, Field


class PROptions(BaseModel):
    """Pull request creation options."""

    title: str = ""
    description: str = ""
    reviewers: list[str] = Field(default_factory=list)


class Task(BaseModel):
    """A unit of work dispatched to a Dev Box worker."""

    id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    repo: str = ""
    branch: str = "main"
    task_type: str = "backend"  # backend | frontend | test | docs
    prompt: str = ""
    assigned_agent: str = "agency-copilot"
    status: str = "pending"  # pending | running | completed | failed
    result_branch: str = ""
    commit_message: str = ""
    pr_options: PROptions = Field(default_factory=PROptions)

    # ADO overrides (None = use global defaults)
    ado_org: Optional[str] = None
    ado_project: Optional[str] = None

    # Work item reference
    work_item_id: Optional[int] = None

    # Runtime fields
    worker_id: Optional[str] = None
    created_at: str = Field(
        default_factory=lambda: datetime.now(timezone.utc).isoformat()
    )
    started_at: Optional[str] = None
    completed_at: Optional[str] = None
    error: Optional[str] = None

    def model_post_init(self, __context: object) -> None:
        if not self.result_branch:
            self.result_branch = f"task/{self.id[:8]}"
        if not self.commit_message:
            self.commit_message = f"[sarma] {self.task_type}: {self.prompt[:80]}"
        if not self.pr_options.title:
            self.pr_options.title = self.commit_message

    def to_json(self) -> str:
        return self.model_dump_json()

    @classmethod
    def from_json(cls, data: str | bytes) -> Task:
        return cls.model_validate_json(data)

    def to_dict(self) -> dict:
        return self.model_dump()

    @classmethod
    def from_dict(cls, data: dict) -> Task:
        return cls.model_validate(data)
