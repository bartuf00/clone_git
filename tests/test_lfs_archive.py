"""End-to-end contract tests for the release-only LFS archive runtime."""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

RUNTIME = Path(__file__).resolve().parents[1] / "scripts" / "lfs_archive.py"


def run_runtime(history_env: dict[str, str], args: list[str], cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run([sys.executable, str(RUNTIME), *args], env=history_env, cwd=cwd,
                          capture_output=True, text=True, check=False, timeout=120)


@pytest.fixture
def archived(lfs_history, gh_stub, tmp_path: Path) -> tuple:
    env = {**lfs_history.env, **{key: value for key, value in gh_stub.env.items() if key in ("LFS_GH_STORE",)}, }
    env["PATH"] = f"{gh_stub.bin_dir}{__import__('os').pathsep}{lfs_history.env['PATH']}"
    return lfs_history, env


def test_archive_when_history_contains_lfs_objects(archived) -> None:
    # Given real upstream history with two versions of same.bin and one deleted file.
    lfs_history, env = archived
    # When archiving from the source into the fake target releases.
    result = run_runtime(env, ["archive", lfs_history.source.as_uri(), "owner/target", str(lfs_history.bare)])
    # Then every historical object became a published content-addressed release.
    assert result.returncode == 0, result.stderr
    assert f"LFS archive complete: {len(lfs_history.objects)} historical objects" in result.stdout
    for obj in lfs_history.objects:
        view = run_runtime(env, ["--help"])  # runtime has no view; use stub log through gh env
        assert view.returncode == 0
    store = Path(env["LFS_GH_STORE"])
    logs = [json.loads(line) for line in (store / "log.jsonl").read_text().splitlines()]
    created = [entry["argv"] for entry in logs if entry["argv"][1:2] == ["create"]]
    assert len(created) == len(lfs_history.objects)
    for obj in lfs_history.objects:
        assert any(f"lfs-archive/{obj.oid}" in argv for argv in created)


def test_archive_when_rerun_skips_existing_releases(archived) -> None:
    # Given a completed archive run.
    lfs_history, env = archived
    first = run_runtime(env, ["archive", lfs_history.source.as_uri(), "owner/target", str(lfs_history.bare)])
    assert first.returncode == 0, first.stderr
    # When archiving the same upstream again.
    second = run_runtime(env, ["archive", lfs_history.source.as_uri(), "owner/target", str(lfs_history.bare)])
    # Then objects are verified and skipped, never re-uploaded or clobbered.
    assert second.returncode == 0, second.stderr
    assert second.stdout.count("SKIP") == len(lfs_history.objects)
    logs = [json.loads(line) for line in (Path(env["LFS_GH_STORE"]) / "log.jsonl").read_text().splitlines()]
    uploads_after_rerun = [entry["argv"] for entry in logs[len([e for e in logs if e["argv"][1:2] != ["view"]]):] if entry["argv"][1:2] == ["upload"]]
    assert uploads_after_rerun == []


def test_restore_when_upstream_deleted_recovers_deleted_and_historical_objects(archived, tmp_path: Path) -> None:
    # Given an archived upstream and a fresh target-side checkout missing LFS payloads.
    lfs_history, env = archived
    result = run_runtime(env, ["archive", lfs_history.source.as_uri(), "owner/target", str(lfs_history.bare)])
    assert result.returncode == 0, result.stderr
    checkout = tmp_path / "checkout"
    lfs_history.git(tmp_path, ["clone", lfs_history.bare.as_uri(), str(checkout)])
    lfs_history.git(checkout, ["lfs", "install", "--local"])
    lfs_history.git(checkout, ["config", "lfs.url", "file:///nonexistent/upstream"])
    # When restoring at HEAD with the upstream LFS server unavailable.
    result = run_runtime(env, ["restore", "owner/target"], cwd=checkout)
    # Then the current LFS file has real content fetched from release assets.
    assert result.returncode == 0, result.stderr
    newest = lfs_history.objects[1]
    assert (checkout / newest.path).read_bytes() == newest.content
    # And restoring at the historical commit recovers the old version and the deleted file.
    lfs_history.git(checkout, ["checkout", "historical"])
    result = run_runtime(env, ["restore", "owner/target"], cwd=checkout)
    assert result.returncode == 0, result.stderr
    oldest = lfs_history.objects[0]
    assert (checkout / oldest.path).read_bytes() == oldest.content
    assert (checkout / "deleted.bin").read_bytes() == lfs_history.objects[2].content


def test_restore_when_worktree_dirty_is_refused(archived, tmp_path: Path) -> None:
    # Given an archive and a checkout with an uncommitted change.
    lfs_history, env = archived
    assert run_runtime(env, ["archive", lfs_history.source.as_uri(), "owner/target", str(lfs_history.bare)]).returncode == 0
    checkout = tmp_path / "dirty"
    lfs_history.git(tmp_path, ["clone", lfs_history.bare.as_uri(), str(checkout)])
    (checkout / "unrelated.txt").write_text("local edit\n")
    # When restoring; Then it refuses without touching files.
    result = run_runtime(env, ["restore", "owner/target"], cwd=checkout)
    assert result.returncode != 0
    assert "clean worktree" in result.stderr
    assert (checkout / "unrelated.txt").read_text() == "local edit\n"


def test_archive_when_upstream_object_missing_fails(archived) -> None:
    # Given a repository whose source LFS store cannot provide the object.
    lfs_history, env = archived
    for obj in lfs_history.objects:
        target = lfs_history.upstream_lfs / obj.oid[:2] / obj.oid[2:4] / obj.oid
        if target.exists():
            target.unlink()
    # When archiving; Then it fails clearly rather than archiving pointers.
    result = run_runtime(env, ["archive", lfs_history.source.as_uri(), "owner/target", str(lfs_history.bare)])
    assert result.returncode != 0


def test_restore_when_release_missing_fails_without_target_lfs(archived, tmp_path: Path) -> None:
    # Given a checkout but no archived releases.
    lfs_history, env = archived
    checkout = tmp_path / "checkout"
    lfs_history.git(tmp_path, ["clone", lfs_history.bare.as_uri(), str(checkout)])
    lfs_history.git(checkout, ["config", "lfs.url", "file:///nonexistent/upstream"])
    # When restoring; Then it fails with a clear message instead of contacting any LFS server.
    result = run_runtime(env, ["restore", "owner/target"], cwd=checkout)
    assert result.returncode != 0
    assert "No completed release archive" in result.stderr


def test_archive_when_non404_inspection_error_is_not_absence(archived, monkeypatch: pytest.MonkeyPatch) -> None:
    # Given a permission failure at the release boundary.
    lfs_history, env = archived
    env = {**env, "LFS_GH_ERROR": "HTTP 403: denied"}
    # When archiving; Then the failure is surfaced, never treated as a missing release.
    result = run_runtime(env, ["archive", lfs_history.source.as_uri(), "owner/target", str(lfs_history.bare)])
    assert result.returncode != 0
    assert "Cannot inspect archive release" in result.stderr
