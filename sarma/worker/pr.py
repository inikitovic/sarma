"""Azure DevOps pull request creation via REST API."""

from __future__ import annotations

import base64
from typing import Optional

import requests

from sarma.config import cfg


def _auth_header(pat: str) -> dict[str, str]:
    """Build Basic auth header from a PAT."""
    token = base64.b64encode(f":{pat}".encode()).decode()
    return {"Authorization": f"Basic {token}", "Content-Type": "application/json"}


def _ado_api_url(org: str, project: str, repo: str, resource: str) -> str:
    """Build an Azure DevOps REST API URL."""
    return (
        f"https://dev.azure.com/{org}/{project}/_apis/git/repositories/{repo}/{resource}"
        "?api-version=7.1"
    )


def create_pull_request(
    repo: str,
    source_branch: str,
    target_branch: str,
    title: str,
    description: str = "",
    reviewers: list[str] | None = None,
    org: Optional[str] = None,
    project: Optional[str] = None,
    pat: Optional[str] = None,
) -> dict:
    """Create a pull request in Azure DevOps.

    Args:
        repo: Repository name (or ID).
        source_branch: Source ref, e.g. ``refs/heads/task/abc123``.
        target_branch: Target ref, e.g. ``refs/heads/main``.
        title: PR title.
        description: PR description.
        reviewers: List of reviewer email addresses or unique names.
        org: ADO organization (defaults to config).
        project: ADO project (defaults to config).
        pat: Personal access token (defaults to config).

    Returns:
        The created pull request as a dict.
    """
    org = org or cfg.ADO_ORG
    project = project or cfg.ADO_PROJECT
    pat = pat or cfg.AZURE_DEVOPS_PAT

    if not pat:
        raise ValueError("AZURE_DEVOPS_PAT is required for PR creation")

    # Ensure refs/ prefix
    if not source_branch.startswith("refs/"):
        source_branch = f"refs/heads/{source_branch}"
    if not target_branch.startswith("refs/"):
        target_branch = f"refs/heads/{target_branch}"

    url = _ado_api_url(org, project, repo, "pullrequests")
    headers = _auth_header(pat)

    body: dict = {
        "sourceRefName": source_branch,
        "targetRefName": target_branch,
        "title": title,
        "description": description,
    }

    if reviewers:
        body["reviewers"] = [{"uniqueName": r} for r in reviewers]

    resp = requests.post(url, json=body, headers=headers, timeout=30)
    resp.raise_for_status()
    return resp.json()
