#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# Run: LFS_GH_STORE=/tmp/store python3 tests/lfs_gh_stub.py release view TAG --repo owner/name
"""Offline gh release subset. Every invocation appends store/log.jsonl."""
from __future__ import annotations

import fnmatch
import hashlib
import json
import os
import re
import shutil
import sys
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import assert_never


class Command(Enum):
    CREATE = "create"
    UPLOAD = "upload"
    DOWNLOAD = "download"
    VIEW = "view"
    EDIT = "edit"


@dataclass(frozen=True, slots=True)
class StubError(Exception):
    message: str

    def __str__(self) -> str:
        return self.message


@dataclass(frozen=True, slots=True)
class Request:
    command: Command
    repo: str
    tag: str
    files: tuple[str, ...]
    draft: bool | None
    directory: Path
    patterns: tuple[str, ...]


def parse(argv: list[str]) -> Request:
    if len(argv) < 3 or argv[0] != "release":
        raise StubError("only explicit release commands are supported")
    try:
        command = Command(argv[1])
    except ValueError as error:
        raise StubError("unsupported release command") from error
    values: dict[str, str] = {}
    files: list[str] = []
    patterns: list[str] = []
    draft: bool | None = None
    index = 3
    while index < len(argv):
        token, separator, inline = argv[index].partition("=")
        if token == "--clobber":
            raise StubError("--clobber is forbidden")
        if token == "--draft":
            value = inline if separator else "true"
            if value not in ("true", "false"):
                raise StubError("draft must be true or false")
            draft = value == "true"
        elif token in ("--repo", "-R", "--dir", "-D", "--pattern", "-p", "--json", "--title", "--notes", "--target", "--latest"):
            if separator:
                value = inline
            else:
                index += 1
                if index >= len(argv):
                    raise StubError(f"missing value for {token}")
                value = argv[index]
            if token in ("--pattern", "-p"):
                patterns.append(value)
            else:
                values[token] = value
        elif token == "--verify-tag":
            pass
        elif token.startswith("-"):
            raise StubError(f"unsupported flag: {token}")
        else:
            files.append(argv[index])
        index += 1
    repo = values.get("--repo", values.get("-R", ""))
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise StubError("--repo owner/name is required")
    if not argv[2]:
        raise StubError("tag is required")
    return Request(command, repo, argv[2], tuple(files), draft,
                   Path(values.get("--dir", values.get("-D", "."))), tuple(patterns))


def upload(release: Path, files: tuple[str, ...]) -> None:
    if not files:
        raise StubError("upload requires assets")
    sources = tuple(Path(value.split("#", 1)[0]) for value in files)
    names = tuple(source.name for source in sources)
    if len(set(names)) != len(names):
        raise StubError("duplicate asset name")
    for source in sources:
        if not source.is_file():
            raise StubError(f"asset is not a file: {source}")
        if (release / "assets" / source.name).exists():
            raise StubError(f"asset already exists: {source.name}")
    for source in sources:
        with source.open("rb") as reader, (release / "assets" / source.name).open("xb") as writer:
            shutil.copyfileobj(reader, writer)


def execute(root: Path, request: Request) -> None:
    injected = os.environ.get("LFS_GH_ERROR", "")
    if injected:
        if "404" in injected:
            raise StubError("injected errors must be non-not-found errors")
        raise StubError(injected)
    digest = hashlib.sha256(json.dumps([request.repo, request.tag]).encode()).hexdigest()
    release = root / digest
    if request.command != Command.CREATE and not release.is_dir():
        raise StubError("HTTP 404: release not found")
    match request.command:
        case Command.CREATE:
            if release.exists():
                raise StubError("release already exists")
            (release / "assets").mkdir(parents=True)
            (release / "draft").write_text("true" if request.draft else "false")
            if request.files:
                upload(release, request.files)
        case Command.UPLOAD:
            upload(release, request.files)
        case Command.VIEW:
            assets = [{"name": asset.name, "size": asset.stat().st_size}
                      for asset in sorted((release / "assets").iterdir())]
            print(json.dumps({"isDraft": (release / "draft").read_text() == "true", "assets": assets}))
        case Command.EDIT:
            if request.draft is not None:
                (release / "draft").write_text("true" if request.draft else "false")
        case Command.DOWNLOAD:
            assets = tuple(asset for asset in sorted((release / "assets").iterdir())
                           if not request.patterns or any(fnmatch.fnmatchcase(asset.name, pattern) for pattern in request.patterns))
            if not assets:
                raise StubError("no assets match")
            if any((request.directory / asset.name).exists() for asset in assets):
                raise StubError("download destination already exists")
            request.directory.mkdir(parents=True, exist_ok=True)
            for asset in assets:
                with asset.open("rb") as reader, (request.directory / asset.name).open("xb") as writer:
                    shutil.copyfileobj(reader, writer)
        case unreachable:
            assert_never(unreachable)


def main() -> int:
    store = os.environ.get("LFS_GH_STORE", "")
    if not store:
        print("LFS_GH_STORE is required", file=sys.stderr)
        return 1
    root = Path(store)
    root.mkdir(parents=True, exist_ok=True)
    code = 0
    error_text = ""
    try:
        execute(root, parse(sys.argv[1:]))
    except (StubError, OSError) as error:
        code = 1
        error_text = str(error)
        print(error_text, file=sys.stderr)
    with (root / "log.jsonl").open("a") as log:
        log.write(json.dumps({"argv": sys.argv[1:], "exit_code": code, "error": error_text}) + "\n")
    return code


if __name__ == "__main__":
    sys.exit(main())
