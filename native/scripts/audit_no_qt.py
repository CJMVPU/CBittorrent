#!/usr/bin/env python3
"""Audit every Mach-O in a standalone CBittorrent bundle, without launching it."""

import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys


def output(arguments):
    return subprocess.check_output([str(value) for value in arguments], text=True).strip()


def version_tuple(value):
    parts = tuple(int(part) for part in value.split("."))
    return parts + (0,) * (3 - len(parts))


def validate_minimum_os(lines, path, minimum, executable=False):
    versions = [line.strip().split()[1] for line in lines
                if line.strip().startswith("minos ")]
    if not versions:
        for index, line in enumerate(lines):
            if line.strip() == "cmd LC_VERSION_MIN_MACOSX":
                versions.append(lines[index + 2].strip().split()[1])
    if not versions or any(version_tuple(value) > version_tuple(minimum) for value in versions):
        raise RuntimeError(f"Binary deployment target exceeds macOS {minimum} or is missing: {path}: {versions}")
    if executable and any(version_tuple(value) != version_tuple(minimum) for value in versions):
        raise RuntimeError(f"Executable deployment target must be {minimum}: {versions}")


def resolve_load(name, loader, executable_dir, search_paths, app):
    def expand(value):
        return value.replace("@loader_path", str(loader.parent)).replace(
            "@executable_path", str(executable_dir))
    if name.startswith("@rpath/"):
        candidates = [Path(directory) / name.removeprefix("@rpath/") for directory in search_paths]
    elif name.startswith(("@loader_path/", "@executable_path/")):
        candidates = [Path(expand(name))]
    else:
        raise RuntimeError(f"External dependency in {loader}: {name}")
    for target in candidates:
        if target.is_file():
            if not target.resolve().is_relative_to(app):
                raise RuntimeError(f"Dependency escapes bundle in {loader}: {name}")
            return target.resolve()
    raise RuntimeError(f"Unresolved dependency in {loader}: {name}")


def audit(app):
    app = app.resolve()
    plist_path = app / "Contents/Info.plist"
    with plist_path.open("rb") as stream:
        plist = plistlib.load(stream)
    if plist.get("LSMinimumSystemVersion") != "27.0":
        raise RuntimeError("The app must target macOS 27.0 and newer.")
    executable_dir = app / "Contents/MacOS"
    binaries = []
    graph = {}
    for path in sorted(app.rglob("*")):
        if not path.is_file():
            continue
        if "Mach-O" not in output(["file", "-b", path]):
            continue
        binaries.append(path)
        architectures = output(["lipo", "-archs", path]).split()
        if architectures != ["arm64"]:
            raise RuntimeError(f"Non-arm64 binary: {path}: {architectures}")
        lines = output(["otool", "-l", path]).splitlines()
        validate_minimum_os(lines, path, "27.0", path == executable_dir / "CBittorrent")
        paths = []
        for index, line in enumerate(lines):
            if line.strip() == "cmd LC_RPATH":
                rpath = lines[index + 2].strip()[5:].rsplit(" (offset ", 1)[0]
                expanded = rpath.replace("@loader_path", str(path.parent)).replace(
                    "@executable_path", str(executable_dir))
                if not Path(expanded).is_absolute() or not Path(expanded).resolve().is_relative_to(app):
                    raise RuntimeError(f"External runtime search path in {path}: {rpath}")
                paths.append(expanded)
        loads = output(["otool", "-L", path]).splitlines()[1:]
        # otool lists LC_ID_DYLIB first; it is an identity, not a dependency.
        if any(line.strip() == "cmd LC_ID_DYLIB" for line in lines):
            loads = loads[1:]
        names = []
        for line in loads:
            name = line.strip().split(" (", 1)[0]
            if re.search(r"(?:^|[/])(?:lib)?Qt", name, re.IGNORECASE):
                raise RuntimeError(f"Qt dependency in {path}: {name}")
            if not name.startswith(("/usr/lib/", "/System/Library/")):
                names.append(name)
        graph[path.resolve()] = (paths, names)
    visited = set()
    def visit(path, inherited):
        if path in visited:
            return
        visited.add(path)
        if path not in graph:
            raise RuntimeError(f"Dependency is not an audited Mach-O: {path}")
        own_paths, names = graph[path]
        search_paths = own_paths + inherited
        for name in names:
            visit(resolve_load(name, path, executable_dir, search_paths, app), search_paths)
    executable = executable_dir / "CBittorrent"
    if executable.is_file():
        visit(executable.resolve(), [])
    for path in graph:
        if path not in visited:
            visit(path, [])
    if not binaries or not (executable_dir / "CBittorrent").is_file():
        raise RuntimeError("CBittorrent executable is missing.")
    icon_name = plist.get("CFBundleIconFile", "")
    icon = app / "Contents/Resources" / icon_name
    if not icon_name or not icon.is_file() or icon.read_bytes()[:4] != b"icns":
        raise RuntimeError("The application icon must be a bundled ICNS resource.")
    catalog = app / "Contents/Resources/Assets.car"
    if plist.get("CFBundleIconName") != "AppIcon" or not catalog.is_file():
        raise RuntimeError("System surfaces require a bundled named AppIcon asset catalog.")
    assets = json.loads(output(["xcrun", "assetutil", "--info", catalog]))
    icon_assets = [asset for asset in assets if asset.get("Name") == "AppIcon"
                   and asset.get("AssetType") == "Icon Image"]
    sizes = {asset.get("PixelWidth") for asset in icon_assets}
    if not {16, 32, 64, 128, 256, 512, 1024}.issubset(sizes):
        raise RuntimeError("AppIcon catalog is missing required macOS icon representations.")
    symbol = app / "Contents/Resources/CB-symbol.png"
    if not symbol.is_file() or symbol.read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
        raise RuntimeError("The shared artistic CB menu-bar artwork is missing.")
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
