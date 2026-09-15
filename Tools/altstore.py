#!/usr/bin/env python3
import argparse
import datetime as dt
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import tempfile
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path


IGNORED_ENTITLEMENTS = {
    "application-identifier",
    "com.apple.developer.team-identifier",
}


def _numeric_triplet(value: str, label: str) -> tuple[int, int, int]:
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:[-+].*)?", value.strip())
    if not match:
        raise ValueError(f"{label} must start with a numeric x.y.z version: {value!r}")
    parts = tuple(int(part) for part in match.groups())
    if any(part > 99 for part in parts):
        raise ValueError(f"{label} components must be <= 99: {value!r}")
    return parts


def bundle_build_version(youtube_version: str, ytkace_version: str) -> str:
    youtube_major, youtube_minor, youtube_patch = _numeric_triplet(
        youtube_version, "YouTube version"
    )
    tweak_major, tweak_minor, tweak_patch = _numeric_triplet(
        ytkace_version, "YTKACE version"
    )
    encoded_tweak = tweak_major * 10_000 + tweak_minor * 100 + tweak_patch
    encoded_patch = youtube_patch * 1_000_000 + encoded_tweak
    return f"{youtube_major}.{youtube_minor}.{encoded_patch}"


def _read_main_info(archive: zipfile.ZipFile) -> tuple[str, dict]:
    candidates = [
        name
        for name in archive.namelist()
        if name.startswith("Payload/")
        and name.count("/") == 2
        and name.endswith(".app/Info.plist")
    ]
    if len(candidates) != 1:
        raise RuntimeError(f"expected exactly one app Info.plist, found {candidates}")
    name = candidates[0]
    return name, plistlib.loads(archive.read(name))


def _bundle_roots(root: Path) -> list[Path]:
    return [root] + [p for p in root.rglob("*.appex") if p.is_dir()]


def _privacy_permissions(root: Path) -> dict[str, str]:
    privacy: dict[str, str] = {}
    for bundle in _bundle_roots(root):
        plist_path = bundle / "Info.plist"
        if not plist_path.exists():
            continue
        try:
            with plist_path.open("rb") as handle:
                info = plistlib.load(handle)
        except Exception:
            continue
        for key, value in info.items():
            if key.startswith("NS") and key.endswith("UsageDescription") and isinstance(value, str):
                privacy.setdefault(key, value)
    return dict(sorted(privacy.items()))


def _entitlements(root: Path, ldid: str) -> list[str]:
    keys: set[str] = set()
    for bundle in _bundle_roots(root):
        info_path = bundle / "Info.plist"
        if not info_path.exists():
            continue
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)
        executable = info.get("CFBundleExecutable")
        if not executable:
            continue
        binary = bundle / executable
        if not binary.exists():
            continue
        result = subprocess.run(
            [ldid, "-e", str(binary)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if not result.stdout.strip():
            continue
        entitlements = plistlib.loads(result.stdout)
        keys.update(entitlements.keys())
    keys.difference_update(IGNORED_ENTITLEMENTS)
    return sorted(keys)


def inspect_ipa(path: Path, ldid: str) -> dict:
    with zipfile.ZipFile(path) as archive:
        info_name, info = _read_main_info(archive)
        app_prefix = info_name[: -len("Info.plist")]
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            members = [name for name in archive.namelist() if name.startswith(app_prefix)]
            archive.extractall(tmp_path, members=members)
            app_root = tmp_path / app_prefix.rstrip("/")
            permissions = {
                "entitlements": _entitlements(app_root, ldid),
                "privacy": _privacy_permissions(app_root),
            }

    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)

    return {
        "filename": path.name,
        "bundleIdentifier": info["CFBundleIdentifier"],
        "version": str(info["CFBundleShortVersionString"]),
        "buildVersion": str(info["CFBundleVersion"]),
        "minOSVersion": str(info.get("MinimumOSVersion", "16.0")),
        "size": path.stat().st_size,
        "sha256": digest.hexdigest(),
        "permissions": permissions,
    }


def _youtube_icon_url() -> str:
    url = "https://itunes.apple.com/lookup?bundleId=com.google.ios.youtube&country=us"
    with urllib.request.urlopen(url, timeout=20) as response:
        payload = json.load(response)
    results = payload.get("results") or []
    if not results or not results[0].get("artworkUrl512"):
        raise RuntimeError("could not resolve YouTube artwork URL from the App Store")
    return results[0]["artworkUrl512"]


def generate_source(
    ipa_paths: list[Path],
    repository: str,
    tag: str,
    ytkace_version: str,
    output: Path,
    ldid: str,
    icon_url: str | None,
) -> None:
    builds = [inspect_ipa(path, ldid) for path in ipa_paths]
    if not builds:
        raise RuntimeError("no IPA files were provided")

    bundle_ids = {build["bundleIdentifier"] for build in builds}
    if len(bundle_ids) != 1:
        raise RuntimeError(f"IPAs have different bundle identifiers: {sorted(bundle_ids)}")

    permissions = builds[0]["permissions"]
    for build in builds[1:]:
        if build["permissions"] != permissions:
            raise RuntimeError("IPA permissions differ between builds; AltStore requires one appPermissions set")

    icon_url = icon_url or _youtube_icon_url()
    date = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()
    base_release_url = f"https://github.com/{repository}/releases/download/{urllib.parse.quote(tag, safe='')}"

    versions = []
    for build in builds:
        versions.append(
            {
                "version": build["version"],
                "buildVersion": build["buildVersion"],
                "marketingVersion": f"YTKACE {ytkace_version} · YouTube {build['version']}",
                "date": date,
                "localizedDescription": f"YTKACE {ytkace_version} based on YouTube {build['version']}.",
                "downloadURL": f"{base_release_url}/{urllib.parse.quote(build['filename'])}",
                "size": build["size"],
                "sha256": build["sha256"],
                "minOSVersion": build["minOSVersion"],
            }
        )

    def version_key(entry: dict) -> tuple[int, ...]:
        return tuple(int(part) for part in re.findall(r"\d+", entry["version"]))

    versions.sort(key=version_key, reverse=True)
    raw_base = f"https://raw.githubusercontent.com/{repository}/main"
    source = {
        "name": "YTKACE",
        "identifier": "com.oexi.ytkace.source",
        "subtitle": "YouTube for iOS with YTKACE enhancements",
        "description": "Automatically published sideloadable YTKACE builds for AltStore and compatible clients.",
        "website": f"https://github.com/{repository}",
        "sourceURL": f"https://github.com/{repository}/releases/latest/download/altstore-source.json",
        "iconURL": icon_url,
        "tintColor": "#FF0033",
        "featuredApps": [builds[0]["bundleIdentifier"]],
        "apps": [
            {
                "name": "YouTube + YTKACE",
                "bundleIdentifier": builds[0]["bundleIdentifier"],
                "developerName": "YTKACE",
                "subtitle": "YouTube enhanced with YTKACE",
                "localizedDescription": "YouTube for iOS with YTKACE features, packaged for sideloading.",
                "iconURL": icon_url,
                "tintColor": "#FF0033",
                "category": "photo-video",
                "screenshots": [
                    f"{raw_base}/screenshots/framed/settings.png",
                    f"{raw_base}/screenshots/framed/video-download-menu.png",
                    f"{raw_base}/screenshots/framed/audio-player.png",
                ],
                "versions": versions,
                "appPermissions": permissions,
            }
        ],
        "news": [],
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(source, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description="AltStore helpers for YTKACE")
    subparsers = parser.add_subparsers(dest="command", required=True)

    build_parser = subparsers.add_parser("bundle-build-version")
    build_parser.add_argument("--youtube-version", required=True)
    build_parser.add_argument("--ytkace-version", required=True)

    source_parser = subparsers.add_parser("source")
    source_parser.add_argument("--ipa", action="append", required=True)
    source_parser.add_argument("--repository", required=True)
    source_parser.add_argument("--tag", required=True)
    source_parser.add_argument("--ytkace-version", required=True)
    source_parser.add_argument("--output", required=True)
    source_parser.add_argument("--ldid", default=shutil.which("ldid") or "ldid")
    source_parser.add_argument("--icon-url")

    args = parser.parse_args()
    if args.command == "bundle-build-version":
        print(bundle_build_version(args.youtube_version, args.ytkace_version))
        return

    generate_source(
        [Path(path) for path in args.ipa],
        args.repository,
        args.tag,
        args.ytkace_version,
        Path(args.output),
        args.ldid,
        args.icon_url,
    )


if __name__ == "__main__":
    main()
