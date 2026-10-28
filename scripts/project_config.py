#!/usr/bin/env python3
"""Read project metadata and generate build metadata from VERSION."""

import argparse
import os
from pathlib import Path
import plistlib
import re


ROOT = Path(__file__).resolve().parent.parent
PROJECT_REPOSITORY = "trah01/fsearch-gui"
UPSTREAM_URL = "https://github.com/noahdunnagan/fsearch"


def project_version():
    version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
    if not re.fullmatch(r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)", version):
        raise ValueError("VERSION 必须是 major.minor.patch 格式，例如 0.1.0")
    return version


def sync_cargo(version):
    # Cargo requires literal versions in its manifest and lockfile.
    for name, pattern in (
        ("Cargo.toml", r'(?m)^(version\s*=\s*)"[^"]+"'),
        ("Cargo.lock", r'(\[\[package\]\]\nname = "fsearch"\nversion = )"[^"]+"'),
    ):
        path = ROOT / name
        before = path.read_text(encoding="utf-8")
        after, count = re.subn(pattern, lambda match: f'{match.group(1)}"{version}"', before, count=1)
        if count != 1:
            raise ValueError(f"无法同步 {name} 中的包版本")
        if before != after:
            path.write_text(after, encoding="utf-8")


def write_info(version, output):
    repository = os.environ.get("FSEARCH_GITHUB_REPOSITORY", PROJECT_REPOSITORY)
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("GitHub 仓库必须使用 owner/repository 格式")
    project_url = f"https://github.com/{repository}"
    info = {
        "CFBundleExecutable": "FSearch",
        "CFBundleIdentifier": "cn.trah.fsearch.desktop",
        "CFBundleName": "FSearch",
        "CFBundleDisplayName": "FSearch",
        "CFBundleIconFile": "AppIcon.icns",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": version,
        "CFBundleDevelopmentRegion": "en",
        "CFBundleLocalizations": ["zh-Hans", "en"],
        "NSPrincipalClass": "NSApplication",
        "LSMinimumSystemVersion": "13.0",
        "NSHighResolutionCapable": True,
        "NSRemovableVolumesUsageDescription": "FSearch 需要读取外置硬盘中的文件名，以建立文件搜索索引。",
        "NSNetworkVolumesUsageDescription": "FSearch 需要读取已连接网络磁盘中的文件名，以便搜索文件。",
        "FSearchProjectURL": project_url,
        "FSearchUpstreamURL": UPSTREAM_URL,
        "FSearchUpdateRepository": repository,
    }
    Path(output).parent.mkdir(parents=True, exist_ok=True)
    with open(output, "wb") as stream:
        plistlib.dump(info, stream, sort_keys=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("version", "sync-cargo", "write-info"))
    parser.add_argument("--tag", help="校验发布标签是否等于 v 加 VERSION")
    parser.add_argument("--output", help="Info.plist 输出路径")
    args = parser.parse_args()
    try:
        version = project_version()
        if args.tag and args.tag != f"v{version}":
            raise ValueError(f"标签 {args.tag} 与 VERSION 的 v{version} 不一致")
        if args.command == "version":
            print(version)
        elif args.command == "sync-cargo":
            sync_cargo(version)
        elif args.command == "write-info":
            if not args.output:
                parser.error("write-info 需要 --output")
            write_info(version, args.output)
    except (OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
