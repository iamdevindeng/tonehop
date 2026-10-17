#!/usr/bin/python3
"""Generate an atomic, deterministic build identity from the Xcode build phase.

Uses only Python's standard library, supplied with the required Xcode tools.
The digest is independent of Git, so untracked sources and source archives work.
Git dirty describes the whole checkout; sourceDigest describes product inputs.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile


INPUT_DIRECTORIES = (
    "ToneHop/Sources",
    "ToneHop/Resources",
    "ToneHop/Tests",
    "ToneHop/ToneHop.xcodeproj/xcshareddata",
    "script",
)
INPUT_FILES = (
    "ToneHop/Info.plist",
    "ToneHop/ToneHop-Bridging-Header.h",
    "ToneHop/ToneHop.xcodeproj/project.pbxproj",
)
EXCLUDED_DIRECTORIES = {
    ".git", "__pycache__", "build", "deriveddata", "generated", "logs",
    "testresults", "evidence", "docs", "xcuserdata",
}
EXCLUDED_SUFFIXES = {".md", ".markdown", ".rst", ".log", ".pyc", ".xcuserstate"}


def source_files(root, output):
    files = set()
    for relative in INPUT_FILES:
        candidate = root / relative
        if candidate.is_file():
            files.add(candidate)
    # Future signing/build settings must participate without listing each name.
    for pattern in ("*.xcconfig", "*.entitlements"):
        files.update((root / "ToneHop").glob(pattern))
    for relative in INPUT_DIRECTORIES:
        directory = root / relative
        if not directory.exists():
            continue
        if directory.is_symlink():
            raise ValueError("Source directory symlinks require an explicit digest input: " + str(directory))
        for base, directories, names in os.walk(directory, followlinks=False):
            directories[:] = sorted(name for name in directories
                                    if name.lower() not in EXCLUDED_DIRECTORIES)
            for name in directories:
                if (Path(base) / name).is_symlink():
                    raise ValueError("Source directory symlinks require an explicit digest input: " + str(Path(base) / name))
            for name in names:
                path = Path(base) / name
                if name == ".DS_Store" or path.suffix.lower() in EXCLUDED_SUFFIXES:
                    continue
                if path.is_file() and path.resolve() != output:
                    files.add(path)
    return sorted(files, key=lambda path: path.relative_to(root).as_posix())


def source_identity(root, output):
    files = source_files(root, output)
    if not files:
        raise ValueError("No ToneHop source inputs found in " + str(root))
    digest = hashlib.sha256(b"ToneHop.source-manifest.v1\0")
    for path in files:
        relative = path.relative_to(root).as_posix().encode("utf-8")
        executable = bool(path.stat().st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH))
        # Delimit paths and hash contents separately; whitespace/newlines are safe.
        digest.update(relative + b"\0")
        digest.update(b"executable\0" if executable else b"regular\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
        digest.update(b"\0")
    return digest.hexdigest(), len(files)


def git_identity(root):
    def git(*arguments):
        return subprocess.run(["/usr/bin/git", "-C", str(root), *arguments], check=True,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              timeout=10).stdout
    try:
        # Do not borrow an enclosing repository's identity for an extracted tree.
        top = Path(os.fsdecode(git("rev-parse", "--show-toplevel").rstrip(b"\n"))).resolve()
        if top != root:
            return "unknown", "unknown"
        commit = git("rev-parse", "--verify", "HEAD").decode("ascii").strip()
        dirty = bool(git("status", "--porcelain=v1", "--untracked-files=all"))
        return commit, "dirty" if dirty else "clean"
    except (OSError, ValueError, UnicodeError, subprocess.SubprocessError):
        return "unknown", "unknown"


def generate(root, output, version, build_number, configuration):
    root = Path(root).resolve(strict=True)
    output = Path(output).resolve()
    source_digest, file_count = source_identity(root, output)
    commit, working_tree = git_identity(root)
    information = {
        "schemaVersion": 1,
        "applicationVersion": version or "unknown",
        "buildNumber": build_number or "unknown",
        "configuration": configuration or "unknown",
        "gitCommit": commit,
        "gitWorkingTreeState": working_tree,
        "sourceDigestAlgorithm": "sha256-manifest-v1",
        "sourceDigest": source_digest,
        "sourceFileCount": file_count,
    }
    data = (json.dumps(information, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")
    output.parent.mkdir(parents=True, exist_ok=True)
    # Always recompute. Preserve mtime only if the newly computed identity matches.
    if output.is_file() and output.read_bytes() == data:
        return information
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=output.parent, prefix=".BuildInfo-", delete=False) as file:
            temporary = Path(file.name)
            file.write(data)
        temporary.chmod(0o644)
        os.replace(temporary, output)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()
    return information


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--version", default=os.environ.get("MARKETING_VERSION", "unknown"))
    parser.add_argument("--build-number", default=os.environ.get("CURRENT_PROJECT_VERSION", "unknown"))
    parser.add_argument("--configuration", default=os.environ.get("CONFIGURATION", "unknown"))
    arguments = parser.parse_args()
    try:
        generate(arguments.root, arguments.output, arguments.version,
                 arguments.build_number, arguments.configuration)
    except (OSError, ValueError, UnicodeError) as error:
        # A failed phase fails the build; a previous resource is not a new result.
        print("error: Cannot generate ToneHop BuildInfo: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
