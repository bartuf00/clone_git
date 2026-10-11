#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Archive upstream Git LFS payloads as content-addressed target release assets and restore them locally.

Single-file distribution: the installer copies exactly this file into target repositories.
"""
# allow: SIZE_OK — single-file runtime is the distribution contract

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Final, TypeAlias, override

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
CHUNK_BYTES: Final = 1024**3
MAX_CHUNKS: Final = 999
OID_PATTERN: Final = re.compile(r"[0-9a-f]{64}")
TAG_PREFIX: Final = "lfs-archive/"


@dataclass(frozen=True, slots=True)
class ArchiveError(Exception):
    detail: str

    @override
    def __str__(self) -> str:
        return self.detail


def json_mapping(text: str) -> dict[str, JsonValue]:
    value: JsonValue = json.loads(text)
    if not isinstance(value, dict):
        raise ArchiveError("Expected a JSON object")
    return value


def text_field(value: JsonValue) -> str:
    if not isinstance(value, str):
        raise ArchiveError("Expected a JSON string")
    return value


def size_field(value: JsonValue) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise ArchiveError("Expected a nonnegative byte count")
    return value


@dataclass(frozen=True, slots=True)
class Pointer:
    oid: str
    size: int

    def __post_init__(self) -> None:
        if not OID_PATTERN.fullmatch(self.oid) or self.size < 0:
            raise ArchiveError("Invalid LFS SHA-256 pointer")

    def serialize(self) -> str:
        return f"version https://git-lfs.github.com/spec/v1\noid sha256:{self.oid}\nsize {self.size}\n"


@dataclass(frozen=True, slots=True)
class Chunk:
    name: str
    size: int
    sha256: str


@dataclass(frozen=True, slots=True)
class Manifest:
    pointer: Pointer
    chunks: tuple[Chunk, ...]

    def serialize(self) -> str:
        return json.dumps({"version": 1, "oid": self.pointer.oid, "size": self.pointer.size,
                           "chunks": [{"name": part.name, "size": part.size, "sha256": part.sha256}
                                      for part in self.chunks]}, sort_keys=True) + "\n"

    @classmethod
    def parse(cls, text: str, pointer: Pointer) -> Manifest:
        data = json_mapping(text)
        if data.get("version") != 1 or data.get("oid") != pointer.oid or data.get("size") != pointer.size:
            raise ArchiveError(f"Manifest does not match LFS object {pointer.oid}")
        parts = data.get("chunks")
        if not isinstance(parts, list) or not 1 <= len(parts) <= MAX_CHUNKS:
            raise ArchiveError("Invalid archive chunk count")
        chunks: list[Chunk] = []
        for index, part in enumerate(parts):
            if not isinstance(part, dict):
                raise ArchiveError("Invalid chunk descriptor")
            name, size, digest = text_field(part.get("name")), size_field(part.get("size")), text_field(part.get("sha256"))
            if name != f"{pointer.oid}.part{index:04d}" or size > CHUNK_BYTES or not OID_PATTERN.fullmatch(digest):
                raise ArchiveError("Invalid archive chunk name, size or digest")
            chunks.append(Chunk(name, size, digest))
        if sum(part.size for part in chunks) != pointer.size:
            raise ArchiveError("Archive chunk sizes do not match object size")
        return cls(pointer, tuple(chunks))


def verify_file(path: Path, pointer: Pointer) -> None:
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    if path.stat().st_size != pointer.size or digest != pointer.oid:
        raise ArchiveError(f"Size or SHA-256 mismatch for {path.name}")


def make_chunks(source: Path, pointer: Pointer, directory: Path, chunk_size: int = CHUNK_BYTES) -> Manifest:
    verify_file(source, pointer)
    if not 1 <= chunk_size <= CHUNK_BYTES or max(1, -(-pointer.size // chunk_size)) > MAX_CHUNKS:
        raise ArchiveError("Object exceeds release chunk limits")
    directory.mkdir(parents=True, exist_ok=True)
    chunks: list[Chunk] = []
    with source.open("rb") as stream:
        remaining = pointer.size
        while remaining or not chunks:
            name = f"{pointer.oid}.part{len(chunks):04d}"
            size = min(remaining, chunk_size)
            digest = hashlib.sha256()
            with (directory / name).open("wb") as target:
                written = 0
                while written < size:
                    block = stream.read(min(1024**2, size - written))
                    if not block:
                        raise ArchiveError("Source object changed while archiving")
                    _ = target.write(block)
                    digest.update(block)
                    written += len(block)
            chunks.append(Chunk(name, size, digest.hexdigest()))
            remaining -= size
    return Manifest(pointer, tuple(chunks))


def git(repository: Path, *arguments: str) -> str:
    return subprocess.check_output(["git", "-C", str(repository), *arguments], text=True,
                                   env=os.environ | {"GIT_MASTER": "1", "GIT_LFS_SKIP_SMUDGE": "1",
                                                     "GIT_LFS_SKIP_PUSH": "1", "GIT_TERMINAL_PROMPT": "0"}).strip()


def pointers(repository: Path, historical: bool) -> tuple[Pointer, ...]:
    if shutil.which("git-lfs") is None:
        raise ArchiveError("git-lfs is required; install it (ubuntu-latest runners include it)")
    arguments = ["lfs", "ls-files", "--json"] + (["--all"] if historical else [])
    data = json_mapping(git(repository, *arguments))
    files = data.get("files")
    if files is None:
        return ()
    if not isinstance(files, list):
        raise ArchiveError("Invalid git lfs ls-files JSON")
    found: dict[str, Pointer] = {}
    for item in files:
        if not isinstance(item, dict):
            raise ArchiveError("Invalid LFS file descriptor")
        pointer = Pointer(text_field(item.get("oid")), size_field(item.get("size")))
        if pointer.oid in found and found[pointer.oid] != pointer:
            raise ArchiveError("Inconsistent sizes for one LFS object")
        found[pointer.oid] = pointer
    return tuple(found.values())


def lfs_endpoint(source: str) -> str:
    """Resolve the LFS object store for the source.

    Git LFS treats file:// URLs and local paths as standalone-file storage rooted at the
    repository's own Git directory (the working-tree .git directory, or the bare repo itself).
    """
    if source.startswith("file://"):
        path = Path(source.removeprefix("file://"))
    elif source.startswith("https://github.com/"):
        return (source if source.endswith(".git") else source.rstrip("/") + ".git") + "/info/lfs"
    else:
        path = Path(source)
        if not path.exists():
            raise ArchiveError(f"Source repository not found: {source}")
    git_dir = path if (path / "HEAD").is_file() else path / ".git"
    if not (git_dir / "HEAD").is_file():
        raise ArchiveError(f"Source is not a Git repository: {source}")
    return git_dir.resolve().as_uri()


def download_object(repository: Path, source: str, pointer: Pointer, destination: Path) -> None:
    environment = os.environ | {"GIT_MASTER": "1", "GIT_LFS_SKIP_SMUDGE": "0", "GIT_LFS_SKIP_PUSH": "1",
                                "GIT_TERMINAL_PROMPT": "0"}
    with destination.open("wb") as output:
        _ = subprocess.run(["git", "-C", str(repository), "-c", f"lfs.url={lfs_endpoint(source)}",
                            "-c", "lfs.fetchinclude=", "-c", "lfs.fetchexclude=",
                            "-c", "lfs.skipdownloaderrors=false", "-c", "lfs.remote.autodetect=false",
                            "-c", "lfs.remote.searchall=false", "lfs", "smudge"],
                           input=pointer.serialize().encode(), stdout=output, env=environment, check=True)


def media_directory(repository: Path) -> Path:
    for line in git(repository, "lfs", "env").splitlines():
        if line.startswith("LocalMediaDir="):
            return Path(line.removeprefix("LocalMediaDir="))
    raise ArchiveError("Git LFS did not report its local object directory")


@dataclass(frozen=True, slots=True)
class Release:
    draft: bool
    assets: tuple[tuple[str, int], ...]


@dataclass(frozen=True, slots=True)
class Releases:
    repository: str

    def command(self, *arguments: str) -> str:
        return subprocess.check_output(["gh", "release", *arguments, "--repo", self.repository], text=True).strip()

    def view(self, tag: str) -> Release | None:
        result = subprocess.run(["gh", "release", "view", tag, "--repo", self.repository,
                                 "--json", "isDraft,assets"], text=True, capture_output=True)
        if result.returncode:
            if "HTTP 404" in result.stderr:
                return None
            raise ArchiveError(f"Cannot inspect archive release: {result.stderr.strip()}")
        data = json_mapping(result.stdout)
        draft, assets = data.get("isDraft"), data.get("assets")
        if not isinstance(draft, bool) or not isinstance(assets, list):
            raise ArchiveError("Invalid release metadata")
        parsed: list[tuple[str, int]] = []
        for asset in assets:
            if not isinstance(asset, dict):
                raise ArchiveError("Invalid release asset metadata")
            parsed.append((text_field(asset.get("name")), size_field(asset.get("size"))))
        if len(dict(parsed)) != len(parsed):
            raise ArchiveError("Duplicate release asset names")
        return Release(draft, tuple(parsed))

    def download(self, tag: str, name: str, directory: Path) -> Path:
        _ = self.command("download", tag, "--pattern", name, "--dir", str(directory))
        return directory / name

    def manifest(self, pointer: Pointer, directory: Path) -> Manifest:
        path = self.download(TAG_PREFIX + pointer.oid, "manifest.json", directory)
        return Manifest.parse(path.read_text(encoding="utf-8"), pointer)

    def verify(self, manifest: Manifest, directory: Path) -> None:
        tag = TAG_PREFIX + manifest.pointer.oid
        release = self.view(tag)
        if release is None:
            raise ArchiveError("Archive release disappeared")
        expected = {part.name: part.size for part in manifest.chunks}
        expected["manifest.json"] = len(manifest.serialize().encode())
        if dict(release.assets) != expected:
            raise ArchiveError("Archive release has missing or unexpected assets")
        for part in manifest.chunks:
            path = self.download(tag, part.name, directory)
            verify_file(path, Pointer(part.sha256, part.size))
            path.unlink()

    def publish(self, manifest: Manifest, directory: Path) -> None:
        tag = TAG_PREFIX + manifest.pointer.oid
        release = self.view(tag)
        if release is None:
            _ = self.command("create", tag, "--draft", "--latest=false",
                             "--title", f"LFS archive {manifest.pointer.oid}",
                             "--notes", "Content-addressed LFS backup; restore with lfs_archive.py.")
            release = Release(True, ())
        if not release.draft:
            raise ArchiveError("Refusing to modify a published archive")
        manifest_path = directory / "manifest.json"
        _ = manifest_path.write_text(manifest.serialize(), encoding="utf-8")
        sizes = dict(release.assets)
        expected_names = {"manifest.json", *(part.name for part in manifest.chunks)}
        if set(sizes) - expected_names:
            raise ArchiveError("Draft contains unexpected archive assets")
        for path in (manifest_path, *(directory / part.name for part in manifest.chunks)):
            if path.name in sizes:
                existing = self.download(tag, path.name, directory / "existing")
                if existing.read_bytes() != path.read_bytes():
                    raise ArchiveError(f"Refusing to overwrite conflicting draft asset {path.name}")
            else:
                _ = self.command("upload", tag, str(path))
        _ = self.command("edit", tag, "--draft=false", "--latest=false")


def archive(source: str, target: str, repository: Path) -> int:
    releases = Releases(target)
    objects = pointers(repository, True)
    for pointer in objects:
        with tempfile.TemporaryDirectory(prefix="lfs-archive-") as temporary:
            directory = Path(temporary)
            release = releases.view(TAG_PREFIX + pointer.oid)
            if release is not None and not release.draft:
                manifest = releases.manifest(pointer, directory)
                releases.verify(manifest, directory)
                print(f"SKIP {pointer.oid} (verified release archive)")
                continue
            payload = directory / "object"
            download_object(repository, source, pointer, payload)
            manifest = make_chunks(payload, pointer, directory / "chunks")
            releases.publish(manifest, directory / "chunks")
            print(f"ARCHIVED {pointer.oid} ({pointer.size} bytes)")
    print(f"LFS archive complete: {len(objects)} historical objects; no target LFS uploads")
    return len(objects)


def restore(target: str) -> None:
    repository = Path.cwd()
    if git(repository, "status", "--porcelain"):
        raise ArchiveError("Restore requires a clean worktree; modified files will not be overwritten")
    releases = Releases(target)
    media = media_directory(repository)
    for pointer in pointers(repository, False):
        destination = media / pointer.oid[:2] / pointer.oid[2:4] / pointer.oid
        if destination.exists():
            verify_file(destination, pointer)
            continue
        with tempfile.TemporaryDirectory(prefix="lfs-restore-") as temporary:
            directory = Path(temporary)
            release = releases.view(TAG_PREFIX + pointer.oid)
            if release is None or release.draft:
                raise ArchiveError(f"No completed release archive for {pointer.oid}")
            manifest = releases.manifest(pointer, directory)
            payload = directory / "object"
            with payload.open("wb") as output:
                for part in manifest.chunks:
                    path = releases.download(TAG_PREFIX + pointer.oid, part.name, directory)
                    verify_file(path, Pointer(part.sha256, part.size))
                    with path.open("rb") as stream:
                        shutil.copyfileobj(stream, output)
                    path.unlink()
            verify_file(payload, pointer)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(payload), str(destination))
            print(f"RESTORED {pointer.oid} ({pointer.size} bytes)")
    _ = git(repository, "lfs", "checkout")
    print("LFS files restored from releases into the local checkout; no LFS server uploads")


def run_archive(source: str, target: str, local: str | None) -> None:
    if local is not None:
        _ = archive(source, target, Path(local))
        return
    with tempfile.TemporaryDirectory(prefix="lfs-source-") as temporary:
        repository = Path(temporary) / "source.git"
        _ = subprocess.run(["git", "clone", "--bare", source, str(repository)], check=True,
                           env=os.environ | {"GIT_MASTER": "1", "GIT_LFS_SKIP_SMUDGE": "1",
                                             "GIT_LFS_SKIP_PUSH": "1", "GIT_TERMINAL_PROMPT": "0"})
        _ = archive(source, target, repository)


def main() -> int:
    arguments = sys.argv[1:]
    if arguments == ["--help"]:
        print("Usage: lfs_archive.py archive UPSTREAM_URL OWNER/REPO [LOCAL_BARE_REPOSITORY]\n"
              "       lfs_archive.py restore OWNER/REPO   (run in a clean checkout)")
        return 0
    try:
        match arguments:
            case ["archive", source, target, *local] if len(local) <= 1:
                run_archive(source, target, local[0] if local else None)
            case ["restore", target]:
                if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", target):
                    raise ArchiveError("Target must be OWNER/REPO")
                restore(target)
            case _:
                print("Invalid arguments; use --help", file=sys.stderr)
                return 2
        return 0
    except (ArchiveError, OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"LFS archive failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
