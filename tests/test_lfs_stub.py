"""Contract tests for the offline GitHub boundary, not the archive format."""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from collections.abc import Mapping, Sequence
from typing import Protocol

import pytest

class HistoryObject(Protocol):
    path: str
    oid: str
    content: bytes
    commit: str
    size: int


class LfsHistory(Protocol):
    source: Path
    bare: Path
    objects: Sequence[HistoryObject]

    def git(self, repo: Path, args: list[str]) -> subprocess.CompletedProcess[str]: ...


class GhStub(Protocol):
    log: Path
    env: Mapping[str, str]

    def run(self, args: list[str]) -> subprocess.CompletedProcess[str]: ...


def gh(tmp_path: Path, args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(Path(__file__).with_name("lfs_gh_stub.py")), *args],
        env={**os.environ, "LFS_GH_STORE": str(tmp_path / "store")},
        capture_output=True, text=True, timeout=10, check=False,
    )


def create(tmp_path: Path) -> None:
    result = gh(tmp_path, ["release", "create", "archive", "--repo", "owner/name", "--draft"])
    assert result.returncode == 0, result.stderr


def test_missing_release_when_viewed(tmp_path: Path) -> None:
    # Given an empty store; When viewing a missing tag.
    result = gh(tmp_path, ["release", "view", "archive", "--repo", "owner/name"])
    # Then only a missing release gets the not-found marker.
    assert result.returncode != 0 and "HTTP 404" in result.stderr


def test_draft_when_created(tmp_path: Path) -> None:
    # Given an empty store; When creating a draft.
    create(tmp_path)
    # Then view exposes draft state and an empty asset inventory.
    result = gh(tmp_path, ["release", "view", "archive", "--repo", "owner/name", "--json", "isDraft,assets"])
    assert json.loads(result.stdout) == {"isDraft": True, "assets": []}


def test_published_when_edited(tmp_path: Path) -> None:
    # Given a draft.
    create(tmp_path)
    # When publishing.
    result = gh(tmp_path, ["release", "edit", "archive", "--repo", "owner/name", "--draft=false"])
    # Then view reports publication.
    assert result.returncode == 0, result.stderr
    assert json.loads(gh(tmp_path, ["release", "view", "archive", "--repo", "owner/name"]).stdout)["isDraft"] is False


def test_bytes_when_uploaded_and_downloaded(tmp_path: Path) -> None:
    # Given a draft containing a binary asset.
    create(tmp_path)
    asset = tmp_path / "chunk.bin"
    asset.write_bytes(b"\x00archive\xff")
    upload = gh(tmp_path, ["release", "upload", "archive", str(asset), "--repo", "owner/name"])
    assert upload.returncode == 0, upload.stderr
    # When downloading an exact pattern.
    result = gh(tmp_path, ["release", "download", "archive", "--repo", "owner/name", "--pattern", "chunk.bin", "--dir", str(tmp_path / "out")])
    # Then bytes and advertised inventory survive the boundary.
    assert result.returncode == 0, result.stderr
    assert (tmp_path / "out/chunk.bin").read_bytes() == b"\x00archive\xff"
    assert json.loads(gh(tmp_path, ["release", "view", "archive", "--repo", "owner/name"]).stdout)["assets"] == [{"name": "chunk.bin", "size": 9}]


@pytest.mark.parametrize("args", [
    ["release", "view", "archive"],
    ["release", "upload", "archive", "--repo", "owner/name", "--clobber"],
    ["api", "repos/owner/name"],
])
def test_rejected_when_unsafe_command(tmp_path: Path, args: list[str]) -> None:
    # Given an unsafe command; When invoking it.
    result = gh(tmp_path, args)
    # Then it is not mistaken for a missing release.
    assert result.returncode != 0 and "HTTP 404" not in result.stderr


@pytest.mark.parametrize("operation", ["upload", "download", "create"])
def test_rejected_when_destination_exists(tmp_path: Path, operation: str) -> None:
    # Given an existing release and asset.
    create(tmp_path)
    asset = tmp_path / "chunk.bin"
    asset.write_bytes(b"original")
    assert gh(tmp_path, ["release", "upload", "archive", str(asset), "--repo", "owner/name"]).returncode == 0
    args = ["release", operation, "archive", "--repo", "owner/name"]
    if operation == "upload":
        asset.write_bytes(b"replacement")
        args.append(str(asset))
    if operation == "download":
        args.extend(["--dir", str(tmp_path)])
    # When attempting an overwrite.
    result = gh(tmp_path, args)
    # Then no clobber is performed.
    assert result.returncode != 0 and "HTTP 404" not in result.stderr
    if operation == "upload":
        assert gh(tmp_path, ["release", "download", "archive", "--repo", "owner/name", "--dir", str(tmp_path / "check")]).returncode == 0
        assert (tmp_path / "check/chunk.bin").read_bytes() == b"original"


def test_non404_when_failure_injected(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    # Given an injected authorization failure.
    monkeypatch.setenv("LFS_GH_ERROR", "HTTP 403: denied")
    # When viewing a tag.
    result = gh(tmp_path, ["release", "view", "archive", "--repo", "owner/name"])
    # Then callers cannot confuse it with absence.
    assert result.returncode != 0 and result.stderr.strip() == "HTTP 403: denied"


def test_repo_isolation_and_log_when_viewed(tmp_path: Path) -> None:
    # Given a release in a different repository.
    create(tmp_path)
    # When viewing the same tag in another repository.
    result = gh(tmp_path, ["release", "view", "archive", "--repo", "other/name"])
    # Then the miss and its invocation are recorded independently.
    assert "HTTP 404" in result.stderr
    entries = [json.loads(line) for line in (tmp_path / "store/log.jsonl").read_text().splitlines()]
    assert entries[-1]["argv"] == ["release", "view", "archive", "--repo", "other/name"]
    assert entries[-1]["exit_code"] == 1


def test_history_when_fetched_from_file_upstream(lfs_history: LfsHistory) -> None:
    # Given a bare copy with no local LFS objects.
    assert not (lfs_history.bare / "lfs/objects").exists()
    # When fetching all historical objects through the file transport.
    lfs_history.git(lfs_history.bare, ["lfs", "fetch", "--all", "origin"])
    # Then both versions of one path and the deleted path have real bytes.
    for item in lfs_history.objects:
        path = lfs_history.bare / "lfs/objects" / item.oid[:2] / item.oid[2:4] / item.oid
        assert path.read_bytes() == item.content
    assert lfs_history.git(lfs_history.source, ["ls-tree", "--name-only", "HEAD"]).stdout.splitlines() == [".gitattributes", "same.bin"]


def test_pointer_when_content_passes_real_filters(lfs_history: LfsHistory) -> None:
    # Given historical filter-produced commits; When reading their Git blobs.
    pointers = [lfs_history.git(lfs_history.bare, ["show", f"{item.commit}:{item.path}"]).stdout
                for item in lfs_history.objects]
    # Then Git holds pointers rather than source payloads.
    for item, pointer in zip(lfs_history.objects, pointers, strict=True):
        assert pointer.splitlines() == ["version https://git-lfs.github.com/spec/v1",
                                       f"oid sha256:{item.oid}", f"size {item.size}"]


def test_shim_when_invoked_through_path(gh_stub: GhStub) -> None:
    # Given the fixture's isolated executable PATH; When running the CLI shim.
    result = subprocess.run(["gh", "release", "create", "tag", "--repo", "owner/name", "--draft"],
                            env=gh_stub.env, capture_output=True, text=True, timeout=10, check=False)
    # Then the local adapter creates a draft and records the invocation.
    assert result.returncode == 0, result.stderr
    assert gh_stub.log.is_file()
    assert json.loads(gh_stub.run(["release", "view", "tag", "--repo", "owner/name"]).stdout)["isDraft"] is True
