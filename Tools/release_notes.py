#!/usr/bin/env python3
import argparse
import pathlib
import re
import subprocess


FIX_RE = re.compile(r"^(?:fix|bugfix)(?:\([^)]*\))?!?:\s*", re.IGNORECASE)
CHANGE_RE = re.compile(
    r"^(?:feat|feature|perf|refactor|docs|build|ci|chore)(?:\([^)]*\))?!?:\s*",
    re.IGNORECASE,
)


def normalize_subject(subject: str) -> str:
    cleaned = FIX_RE.sub("", subject)
    if cleaned == subject:
        cleaned = CHANGE_RE.sub("", subject)
    cleaned = cleaned.strip()
    if cleaned:
        cleaned = cleaned[0].upper() + cleaned[1:]
    return cleaned


def classify(subject: str) -> str:
    return "fix" if FIX_RE.match(subject) else "change"


def collect_commits(base: str, head: str):
    output = subprocess.check_output(
        ["git", "log", "--reverse", "--format=%H%x1f%s", f"{base}..{head}"],
        text=True,
    )
    commits = []
    for line in output.splitlines():
        if not line.strip():
            continue
        sha, subject = line.split("\x1f", 1)
        if subject.startswith("Merge "):
            continue
        commits.append((sha, subject))
    return commits


def render(version: str, repository: str, commits) -> str:
    fixes = []
    changes = []
    for sha, subject in commits:
        item = (
            f"- {normalize_subject(subject)} "
            f"([`{sha[:7]}`](https://github.com/{repository}/commit/{sha}))"
        )
        (fixes if classify(subject) == "fix" else changes).append(item)

    lines = [f"Automated IPA builds for YTKACE v{version}.", ""]
    if fixes:
        lines.extend(["## Bug fixes", *fixes, ""])
    if changes:
        lines.extend(["## Changes", *changes, ""])
    if not fixes and not changes:
        lines.extend(["## Changes", "- No fork-specific changes since upstream.", ""])

    lines.extend(
        [
            "## AltStore",
            f"Source: https://github.com/{repository}/releases/latest/download/altstore-source.json",
            "",
        ]
    )
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    notes = render(
        args.version,
        args.repository,
        collect_commits(args.base, args.head),
    )
    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(notes, encoding="utf-8")


if __name__ == "__main__":
    main()
