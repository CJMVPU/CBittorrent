#!/usr/bin/env python3
"""Audit every Mach-O in a standalone CBittorrent bundle, without launching it."""

import argparse
from pathlib import Path
import plistlib
import re
import subprocess
import sys


def output(arguments):
    return subprocess.check_output([str(value) for value in arguments], text=True).strip()


def audit(app):
    app = app.resolve()
    plist_path = app / "Contents/Info.plist"
    with plist_path.open("rb") as stream:
        plist = plistlib.load(stream)
    if plist.get("LSMinimumSystemVersion") != "27.0":
        raise RuntimeError("The app must target macOS 27.0 and newer.")
    executable_dir = app / "Contents/MacOS"
    frameworks = app / "Contents/Frameworks"
    binaries = []
    for path in sorted(app.rglob("*")):
        if not path.is_file():
            continue
        if "Mach-O" not in output(["file", "-b", path]):
            continue
        binaries.append(path)
        architectures = output(["lipo", "-archs", path]).split()
        if architectures != ["arm64"]:
            raise RuntimeError(f"Non-arm64 binary: {path}: {architectures}")
        loads = output(["otool", "-L", path]).splitlines()[1:]
        for line in loads:
            name = line.strip().split(" (", 1)[0]
            if re.search(r"(?:^|[/])(?:lib)?Qt", name, re.IGNORECASE):
                raise RuntimeError(f"Qt dependency in {path}: {name}")
            if name.startswith(("/usr/lib/", "/System/Library/")):
                continue
            if name.startswith("@rpath/"):
                target = frameworks / name.removeprefix("@rpath/")
            elif name.startswith("@loader_path/"):
                target = path.parent / name.removeprefix("@loader_path/")
            elif name.startswith("@executable_path/"):
                target = executable_dir / name.removeprefix("@executable_path/")
            else:
                raise RuntimeError(f"External dependency in {path}: {name}")
            if not target.exists() or not target.resolve().is_relative_to(app):
                raise RuntimeError(f"Unbundled dependency in {path}: {name}")
        lines = output(["otool", "-l", path]).splitlines()
        if path == executable_dir / "CBittorrent":
            min_versions = [line.strip().split()[1] for line in lines
                            if line.strip().startswith("minos ")]
            if min_versions != ["27.0"]:
                raise RuntimeError(f"Executable deployment target must be 27.0: {min_versions}")
        for index, line in enumerate(lines):
            if line.strip() == "cmd LC_RPATH":
                rpath = lines[index + 2].strip().split(" ")[1]
                if rpath.startswith("/") and not rpath.startswith(("/usr/lib/", "/System/Library/")):
                    raise RuntimeError(f"External runtime search path in {path}: {rpath}")
    if not binaries or not (executable_dir / "CBittorrent").is_file():
        raise RuntimeError("CBittorrent executable is missing.")
    font = app / "Contents/Resources/Fonts/LXGWWenKaiMono-Medium.ttf"
    if not font.is_file() or not font.with_name("OFL.txt").is_file():
        raise RuntimeError("The requested font and its license must be bundled.")
    print(f"PASS: {len(binaries)} arm64 Mach-O files; no Qt; all non-system libraries bundled; macOS 27+.")
    for path in binaries:
        print("  " + str(path.relative_to(app)))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    try:
        audit(parser.parse_args().app)
    except (OSError, subprocess.CalledProcessError, RuntimeError) as error:
        sys.exit(f"FAIL: {error}")
