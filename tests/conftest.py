"""Offline fixtures; builders also work outside pytest for persistent tmux QA."""
from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import sys
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path

import pytest


@dataclass(frozen=True, slots=True)
class LfsObject:
    path: str
    oid: str
    content: bytes
    commit: str

    @property
    def size(self) -> int:
        return len(self.content)


@dataclass(frozen=True, slots=True)
class LfsHistory:
    source: Path
    bare: Path
    upstream_lfs: Path
    objects: tuple[LfsObject, ...]
    commits: tuple[str, ...]
    env: Mapping[str, str]

    def git(self, repo: Path, args: list[str]) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", "-C", str(repo), *args], env=self.env,
            capture_output=True, text=True, check=True, timeout=30,
        )


@dataclass(frozen=True, slots=True)
class GhStub:
    bin_dir: Path
    store: Path
    log: Path
    env: Mapping[str, str]

    def run(self, args: list[str]) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(self.bin_dir / "gh"), *args], env=self.env,
            capture_output=True, text=True, check=False, timeout=10,
        )


def build_gh_stub(root: Path) -> GhStub:
    """Create an executable gh shim and isolated store beneath a caller-owned root."""
    bin_dir = root / "bin"
    bin_dir.mkdir(parents=True)
    store = root / "gh-store"
    store.mkdir()
    shim = bin_dir / "gh"
    adapter = Path(__file__).with_name("lfs_gh_stub.py").resolve()
    shim.write_text(f"#!{sys.executable}\nimport runpy\nrunpy.run_path({str(adapter)!r}, run_name='__main__')\n")
    shim.chmod(0o755)
    env = {**os.environ, "PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}",
           "LFS_GH_STORE": str(store)}
    env.pop("LFS_GH_ERROR", None)
    return GhStub(bin_dir, store, store / "log.jsonl", env)


def build_lfs_history(root: Path, lfs_binary: Path | None = None) -> LfsHistory:
    """Create filter-produced pointers, three source objects, and an object-empty bare clone.

    LFS_GIT_LFS selects the executable; the extracted local binary is a fallback.
    The file:// endpoint is source/.git; no LFS push or target upload is used.
    """
    selected = lfs_binary or Path(os.environ.get("LFS_GIT_LFS", shutil.which("git-lfs") or "/tmp/opencode/usr/bin/git-lfs"))
    if not selected.is_file():
        raise FileNotFoundError(selected)
    root.mkdir(parents=True, exist_ok=True)
    bin_dir = root / "bin"
    bin_dir.mkdir()
    (bin_dir / "git-lfs").symlink_to(selected.resolve())
    home = root / "home"
    home.mkdir()
    env = {key: value for key, value in os.environ.items()
           if not key.startswith("GIT_") and not key.startswith("LFS_")}
    env.update({"PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}",
                "HOME": str(home), "XDG_CONFIG_HOME": str(home),
                "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
                "GIT_MASTER": "1", "GIT_TERMINAL_PROMPT": "0",
                "GIT_LFS_SKIP_SMUDGE": "1"})
    source = root / "source"
    source.mkdir()
    bare = root / "mirror.git"
    history = LfsHistory(source, bare, source / ".git/lfs/objects", (), (), env)
    history.git(source, ["init", "--initial-branch=main"])
    history.git(source, ["config", "user.name", "Offline fixture"])
    history.git(source, ["config", "user.email", "fixture@example.invalid"])
    history.git(source, ["config", "commit.gpgsign", "false"])
    history.git(source, ["lfs", "install", "--local"])
    history.git(source, ["lfs", "track", "*.bin"])
    first = b"first historical version\x00\xff\n"
    second = b"second historical version, different size\x00\xfe\n"
    deleted = b"only in history; deleted from HEAD\x00\xfd\n"
    (source / "same.bin").write_bytes(first)
    (source / "deleted.bin").write_bytes(deleted)
    history.git(source, ["add", "."])
    history.git(source, ["commit", "-m", "Record first LFS versions"])
    old_commit = history.git(source, ["rev-parse", "HEAD"]).stdout.strip()
    history.git(source, ["tag", "historical"])
    (source / "same.bin").write_bytes(second)
    history.git(source, ["rm", "deleted.bin"])
    history.git(source, ["add", "same.bin"])
    history.git(source, ["commit", "-m", "Replace version and delete historical file"])
    new_commit = history.git(source, ["rev-parse", "HEAD"]).stdout.strip()
    history.git(source, ["clone", "--bare", source.as_uri(), str(bare)])
    history.git(bare, ["config", "lfs.url", (source / ".git").as_uri()])
    history.git(bare, ["config", "lfs.storage", str(bare / "lfs")])
    objects = tuple(LfsObject(path, hashlib.sha256(content).hexdigest(), content, commit)
                    for path, content, commit in (("same.bin", first, old_commit),
                                                 ("same.bin", second, new_commit),
                                                 ("deleted.bin", deleted, old_commit)))
    return LfsHistory(source, bare, history.upstream_lfs, objects, (old_commit, new_commit), env)


@pytest.fixture
def gh_stub(tmp_path: Path) -> GhStub:
    return build_gh_stub(tmp_path / "github")


@pytest.fixture
def lfs_history(tmp_path: Path) -> LfsHistory:
    return build_lfs_history(tmp_path / "history")
