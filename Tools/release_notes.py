#!/usr/bin/env python3
import argparse
import pathlib
import re
import subprocess


FIX_RE = re.compile(r"^(?:fix|bugfix)(?:\([^)]*\))?!?:\s*", re.IGNORECASE)
CHANGE_RE = re.compile(
    r"^(?:feat|feature|perf|refactor)(?:\([^)]*\))?!?:\s*",
    re.IGNORECASE,
)
MAINTENANCE_RE = re.compile(
    r"^(?:docs|build|ci|chore|test|tests|style)(?:\([^)]*\))?!?:\s*",
    re.IGNORECASE,
)
PLAIN_FIX_RE = re.compile(r"^fix(?:e[sd])?\b", re.IGNORECASE)
PLAIN_MAINTENANCE_RE = re.compile(
    r"\breadme\b|^release\s+v?\d|^prepare\s+for\b.*\brelease\b",
    re.IGNORECASE,
)
MAINTENANCE_PATH_RE = re.compile(r"^(?:\.github/|Tests/|Tools/)|\.md$")


def normalize_subject(subject: str) -> str:
    cleaned = subject
    for pattern in (FIX_RE, CHANGE_RE, MAINTENANCE_RE):
        stripped = pattern.sub("", subject)
        if stripped != subject:
            cleaned = stripped
            break
    cleaned = cleaned.strip()
    if cleaned:
        cleaned = cleaned[0].upper() + cleaned[1:]
    return cleaned


def is_maintenance_only(files) -> bool:
    return bool(files) and all(MAINTENANCE_PATH_RE.search(path) for path in files)


def classify(subject: str, files=()) -> str:
    if is_maintenance_only(files):
        return "maintenance"
    if FIX_RE.match(subject):
        return "fix"
    if CHANGE_RE.match(subject):
        return "change"
    if MAINTENANCE_RE.match(subject) or PLAIN_MAINTENANCE_RE.search(subject):
        return "maintenance"
    if PLAIN_FIX_RE.match(subject):
        return "fix"
    return "change"


def git(*args: str) -> str:
    return subprocess.check_output(["git", *args], text=True)


def is_ancestor(ancestor: str, descendant: str) -> bool:
    result = subprocess.run(
        ["git", "merge-base", "--is-ancestor", ancestor, descendant],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return result.returncode == 0


def log_commits(*revisions: str):
    output = git(
        "log", "--reverse", "--no-merges", "--name-only",
        "--format=%x1e%H%x1f%s", *revisions,
    )
    commits = []
    for record in output.split("\x1e"):
        if not record.strip():
            continue
        header, _, names = record.partition("\n")
        sha, subject = header.split("\x1f", 1)
        if subject.startswith("Merge "):
            continue
        files = tuple(name for name in names.splitlines() if name.strip())
        commits.append((sha, subject, files))
    return commits


def resolve_base(head: str, upstream: str, since: str | None) -> tuple[str, str | None]:
    """Return the range start and the release tag it came from, if any."""
    if since and is_ancestor(since, head):
        return since, since
    return git("merge-base", head, upstream).strip(), None


def collect_commits(base: str, head: str, upstream: str):
    fork = log_commits(f"{base}..{head}", f"^{upstream}")
    fork_shas = {commit[0] for commit in fork}
    upstream_commits = [
        commit for commit in log_commits(f"{base}..{head}") if commit[0] not in fork_shas
    ]
    return fork, upstream_commits


def _item(repository: str, sha: str, subject: str) -> str:
    return (
        f"- {normalize_subject(subject)} "
        f"([`{sha[:7]}`](https://github.com/{repository}/commit/{sha}))"
    )


def _section(title: str, repository: str, commits, maintenance: list) -> list:
    fixes = []
    changes = []
    for sha, subject, *rest in commits:
        kind = classify(subject, rest[0] if rest else ())
        if kind == "maintenance":
            maintenance.append(_item(repository, sha, subject))
        else:
            (fixes if kind == "fix" else changes).append(_item(repository, sha, subject))
    if not fixes and not changes:
        return []
    lines = [f"## {title}", ""]
    if fixes:
        lines.extend(["### Bug fixes", *fixes, ""])
    if changes:
        lines.extend(["### Changes", *changes, ""])
    return lines


def render(
    version: str,
    repository: str,
    fork_commits,
    upstream_commits=(),
    since_tag: str | None = None,
    head: str | None = None,
) -> str:
    lines = [f"Automated IPA builds for YTKACE v{version}.", ""]
    if since_tag:
        summary = f"Changes since {since_tag}"
        if head:
            summary += (
                f" ([compare](https://github.com/{repository}/compare/{since_tag}...{head}))"
            )
        lines.extend([summary + ".", ""])

    maintenance = []
    body = _section("Fork changes", repository, fork_commits, maintenance)
    body += _section("Upstream changes", repository, upstream_commits, maintenance)
    if not body:
        body = ["## Changes", "- No user-facing changes.", ""]
    lines.extend(body)

    if maintenance:
        lines.extend(
            [
                "<details>",
                f"<summary>Maintenance ({len(maintenance)})</summary>",
                "",
                *maintenance,
                "",
                "</details>",
                "",
            ]
        )

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
    parser.add_argument("--head", required=True)
    parser.add_argument("--upstream", required=True, help="Upstream branch ref, e.g. upstream-release/main")
    parser.add_argument("--since", default="", help="Previous release tag; falls back to the upstream merge-base")
    parser.add_argument("--version", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    base, since_tag = resolve_base(args.head, args.upstream, args.since or None)
    fork_commits, upstream_commits = collect_commits(base, args.head, args.upstream)
    notes = render(
        args.version,
        args.repository,
        fork_commits,
        upstream_commits,
        since_tag=since_tag,
        head=args.head,
    )
    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(notes, encoding="utf-8")


if __name__ == "__main__":
    main()
