import argparse
import subprocess
from collections import defaultdict
from pathlib import Path, PurePosixPath


REPO_ROOT = Path(__file__).resolve().parent
ENCODINGS = {
    "gbk": "gbk",
    "utf8": "utf-8",
    "utf16": "utf-16",
    "gb18030": "gb18030",
}
SOURCE_ENCODINGS = tuple(ENCODINGS)


class ConversionError(Exception):
    """Raised when a changed SAS file cannot be synchronized safely."""


def run_git(*args: str) -> bytes:
    try:
        result = subprocess.run(
            ["git", *args],
            cwd=REPO_ROOT,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except subprocess.CalledProcessError as error:
        detail = error.stderr.decode("utf-8", errors="replace").strip()
        raise ConversionError(f"git {' '.join(args)} failed: {detail}") from error

    return result.stdout


def resolve_commit(ref: str) -> str:
    result = run_git("rev-parse", "--verify", "--end-of-options", f"{ref}^{{commit}}")
    return result.decode("ascii").strip()


def get_changed_files(base_sha: str, head_sha: str) -> dict[PurePosixPath, set[str]]:
    """Return managed SAS files changed between the PR base and head."""
    output = run_git(
        "diff",
        "--no-renames",
        "--name-only",
        "-z",
        f"{base_sha}...{head_sha}",
        "--",
        "src",
    )

    changed_files: dict[PurePosixPath, set[str]] = defaultdict(set)
    for raw_path in output.split(b"\0"):
        if not raw_path:
            continue

        path = PurePosixPath(raw_path.decode("utf-8", errors="surrogateescape"))
        if len(path.parts) < 3 or path.parts[0] != "src":
            continue

        encoding_dir = path.parts[1]
        relative_path = PurePosixPath(*path.parts[2:])
        if (
            encoding_dir not in ENCODINGS
            or relative_path.suffix.lower() != ".sas"
        ):
            continue

        changed_files[relative_path].add(encoding_dir)

    return changed_files


def get_last_changed_commit(
    base_sha: str,
    head_sha: str,
    encoding_dir: str,
    relative_path: PurePosixPath,
) -> str | None:
    pathspec = f":(literal)src/{encoding_dir}/{relative_path.as_posix()}"
    output = run_git(
        "log",
        "-1",
        "--format=%H",
        f"{base_sha}..{head_sha}",
        "--",
        pathspec,
    )
    commit = output.decode("ascii").strip()
    return commit or None


def is_ancestor(ancestor: str, descendant: str) -> bool:
    result = subprocess.run(
        ["git", "merge-base", "--is-ancestor", ancestor, descendant],
        cwd=REPO_ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode not in (0, 1):
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise ConversionError(f"git merge-base --is-ancestor failed: {detail}")
    return result.returncode == 0


def read_source_text(relative_path: PurePosixPath, encoding_dir: str) -> str:
    path = REPO_ROOT / "src" / encoding_dir / Path(*relative_path.parts)
    try:
        return path.read_text(encoding=ENCODINGS[encoding_dir])
    except UnicodeError as error:
        raise ConversionError(
            f"cannot decode {path.relative_to(REPO_ROOT)} as "
            f"{ENCODINGS[encoding_dir]}: {error}"
        ) from error


def choose_source_encoding(
    relative_path: PurePosixPath,
    changed_encodings: set[str],
    base_sha: str,
    head_sha: str,
) -> str | None:
    """Choose the latest unambiguous source copy for one logical SAS file."""
    changed_sources = changed_encodings.intersection(SOURCE_ENCODINGS)
    if not changed_sources:
        raise ConversionError(f"no supported source encoding changed for {relative_path}")

    if len(changed_sources) == 1:
        return next(iter(changed_sources))

    paths = {
        encoding_dir: REPO_ROOT / "src" / encoding_dir / Path(*relative_path.parts)
        for encoding_dir in changed_sources
    }
    existing_encodings = [
        encoding_dir for encoding_dir, path in paths.items() if path.exists()
    ]
    if not existing_encodings:
        return None

    if len(existing_encodings) == len(changed_sources):
        texts = {
            encoding_dir: read_source_text(relative_path, encoding_dir)
            for encoding_dir in existing_encodings
        }
        if len(set(texts.values())) == 1:
            return next(encoding for encoding in ENCODINGS if encoding in changed_sources)

    changed_commits = {
        encoding_dir: get_last_changed_commit(
            base_sha, head_sha, encoding_dir, relative_path
        )
        for encoding_dir in changed_sources
    }
    if any(commit is None for commit in changed_commits.values()):
        raise ConversionError(
            f"could not determine which encoding copy of {relative_path} changed last"
        )

    latest_encodings = [
        encoding_dir
        for encoding_dir, commit in changed_commits.items()
        if not any(
            other_commit != commit and is_ancestor(commit, other_commit)
            for other_commit in changed_commits.values()
        )
    ]
    latest_paths = [paths[encoding_dir] for encoding_dir in latest_encodings]
    if not any(path.exists() for path in latest_paths):
        return None
    if not all(path.exists() for path in latest_paths):
        raise ConversionError(
            f"the latest changes to {relative_path} disagree about whether the "
            "file exists; resolve the conflict in a later commit"
        )

    latest_texts = [
        read_source_text(relative_path, encoding_dir)
        for encoding_dir in latest_encodings
    ]
    if len(set(latest_texts)) == 1:
        return next(
            encoding for encoding in ENCODINGS if encoding in latest_encodings
        )

    raise ConversionError(
        f"the latest changes to {relative_path} contain different text in "
        "multiple encoding directories; resolve the conflict in a later commit"
    )


def remove_all_copies(relative_path: PurePosixPath) -> None:
    for encoding_dir in ENCODINGS:
        path = REPO_ROOT / "src" / encoding_dir / Path(*relative_path.parts)
        path.unlink(missing_ok=True)


def write_all_copies(relative_path: PurePosixPath, text: str) -> None:
    encoded_copies: dict[str, bytes] = {}
    for encoding_dir, codec in ENCODINGS.items():
        try:
            encoded_copies[encoding_dir] = text.encode(codec)
        except UnicodeEncodeError as error:
            code_point = ord(text[error.start])
            raise ConversionError(
                f"{relative_path} contains U+{code_point:04X}, which cannot be "
                f"encoded as {encoding_dir} ({codec})"
            ) from error

    for encoding_dir, contents in encoded_copies.items():
        path = REPO_ROOT / "src" / encoding_dir / Path(*relative_path.parts)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(contents)


def synchronize_changed_files(base_ref: str, head_ref: str) -> None:
    base_sha = resolve_commit(base_ref)
    head_sha = resolve_commit(head_ref)
    changed_files = get_changed_files(base_sha, head_sha)
    if not changed_files:
        print("No managed SAS files changed; nothing to synchronize.")
        return

    for relative_path, changed_encodings in sorted(
        changed_files.items(), key=lambda item: item[0].as_posix()
    ):
        source_encoding = choose_source_encoding(
            relative_path,
            changed_encodings,
            base_sha,
            head_sha,
        )
        if source_encoding is None:
            remove_all_copies(relative_path)
            print(f"Deleted {relative_path} from all encoding directories.")
            continue

        source_path = REPO_ROOT / "src" / source_encoding / Path(*relative_path.parts)
        if not source_path.exists():
            remove_all_copies(relative_path)
            print(f"Deleted {relative_path} from all encoding directories.")
            continue

        text = read_source_text(relative_path, source_encoding)
        write_all_copies(relative_path, text)
        print(f"Synchronized {relative_path} from {source_encoding}.")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Synchronize changed SAS files across supported encodings."
    )
    parser.add_argument("--base-ref", required=True, help="PR base commit or ref")
    parser.add_argument("--head-ref", required=True, help="PR head commit or ref")
    args = parser.parse_args()

    try:
        synchronize_changed_files(args.base_ref, args.head_ref)
    except ConversionError as error:
        parser.exit(1, f"multi_encoding_converter: {error}\n")


if __name__ == "__main__":
    main()
