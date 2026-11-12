#!/usr/bin/env python3
"""Build the native arm64 app, copying (never editing) external libraries."""

import argparse
import hashlib
import json
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import sys

NATIVE = Path(__file__).resolve().parents[1]
ROOT = NATIVE.parent
MINIMUM_MACOS = "27.0"


def run(arguments, **kwargs):
    print("+ " + shlex.join(str(value) for value in arguments), flush=True)
    return subprocess.run([str(value) for value in arguments], check=True, **kwargs)


def output(arguments):
    return subprocess.check_output([str(value) for value in arguments], text=True).strip()


def dependencies(binary):
    lines = output(["otool", "-L", binary]).splitlines()[1:]
    return [line.strip().split(" (", 1)[0] for line in lines]


def rpaths(binary):
    lines = output(["otool", "-l", binary]).splitlines()
    return [lines[index + 2].strip().split(" ")[1]
            for index, line in enumerate(lines)
            if line.strip() == "cmd LC_RPATH"]


def is_system(path):
    return path.startswith(("/usr/lib/", "/System/Library/"))


def resolve_dependency(name, source, executable, search_paths):
    if name.startswith("@loader_path/"):
        candidates = [source.parent / name.removeprefix("@loader_path/")]
    elif name.startswith("@executable_path/"):
        candidates = [executable.parent / name.removeprefix("@executable_path/")]
    elif name.startswith("@rpath/"):
        candidates = []
        for directory in rpaths(source) + search_paths:
            directory = directory.replace("@loader_path", str(source.parent))
            directory = directory.replace("@executable_path", str(executable.parent))
            candidates.append(Path(directory) / name.removeprefix("@rpath/"))
    elif name.startswith("/"):
        candidates = [Path(name)]
    else:
        candidates = [source.parent / name]
    for candidate in candidates:
        if candidate.exists():
            return candidate.resolve()
    raise RuntimeError(f"Cannot resolve {name} loaded by {source}")


def package_libraries(executable, frameworks, search_paths):
    """Resolve the original graph first; mutate only copies inside the bundle."""
    sources = {executable.resolve(): executable}
    queue = [executable.resolve()]
    edges = {}
    while queue:
        source = queue.pop(0)
        links = []
        for name in dependencies(source):
            if is_system(name):
                continue
            target = resolve_dependency(name, source, executable, search_paths)
            if target == source:  # A dylib's first otool entry is its own ID.
                continue
            if target not in sources:
                destination = frameworks / target.name
                if destination in sources.values():
                    raise RuntimeError(f"Conflicting dependency basename: {target.name}")
                shutil.copy2(target, destination)
                destination.chmod(destination.stat().st_mode | 0o200)
                sources[target] = destination
                queue.append(target)
            links.append((name, sources[target]))
        edges[source] = links
    for source, destination in sources.items():
        if destination != executable:
            run(["install_name_tool", "-id", "@rpath/" + destination.name, destination])
        for original, target in edges[source]:
            replacement = ("@rpath/" if destination == executable else "@loader_path/") + target.name
            run(["install_name_tool", "-change", original, replacement, destination])
        # Homebrew build rpaths must not survive in the distributable bundle.
        for path in rpaths(destination):
            if path.startswith(("/opt/", "/usr/local/")):
                run(["install_name_tool", "-delete_rpath", path, destination])
    return sources


def copy_licenses(sources, destination):
    shutil.copy2(ROOT / "COPYING", destination / "CBittorrent-COPYING.txt")
    for path in (ROOT / "COPYING.GPLv2", ROOT / "COPYING.GPLv3"):
        if path.exists():
            shutil.copy2(path, destination / path.name)
    for source in sources:
        cellar = next((parent for parent in source.parents
                       if (parent / "INSTALL_RECEIPT.json").exists()), None)
        if cellar is None:
            continue
        package = cellar.parent.name
        for filename in ("LICENSE", "LICENSE.txt", "LICENSE.md", "COPYING", "NOTICE", "AUTHORS", "AUTHORS.md"):
            license_path = cellar / filename
            if license_path.is_file():
                shutil.copy2(license_path, destination / f"{package}-{filename}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/native")
    parser.add_argument("--configuration", choices=("debug", "release"), default="release")
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("CBittorrent builds only on an Apple Silicon Mac, without Rosetta.")
    for command in ("xcrun", "pkg-config", "otool", "install_name_tool", "codesign"):
        if not shutil.which(command):
            parser.error(f"Missing {command}; see native/README.md.")
    sdk = output(["xcrun", "--sdk", "macosx", "--show-sdk-path"])
    sdk_version = output(["xcrun", "--sdk", "macosx", "--show-sdk-version"])
    if int(sdk_version.split(".")[0]) < 27:
        parser.error("An Xcode macOS 27 or newer SDK is required.")
    version = output(["pkg-config", "--modversion", "libtorrent-rasterbar"])
    version_parts = tuple(int(part) for part in version.split(".")[:2])
    if not (version_parts >= (2, 1) and version_parts < (3, 0)):
        parser.error("libtorrent-rasterbar >= 2.1 and < 3 is required.")
    cflags = shlex.split(output(["pkg-config", "--cflags", "libtorrent-rasterbar"]))
    libs = shlex.split(output(["pkg-config", "--libs", "libtorrent-rasterbar"]))
    # Homebrew's libtorrent .pc omits the transitive Boost include directory.
    if shutil.which("brew"):
        cflags += ["-I" + output(["brew", "--prefix"]) + "/include"]
    output_dir = args.output.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    app = output_dir / "CBittorrent.app"
    if app.exists():
        shutil.rmtree(app)
    contents = app / "Contents"
    executable = contents / "MacOS/CBittorrent"
    frameworks = contents / "Frameworks"
    resources = contents / "Resources"
    objects_dir = output_dir / "objects"
    for directory in (executable.parent, frameworks, resources, objects_dir):
        directory.mkdir(parents=True, exist_ok=True)
    shutil.copy2(NATIVE / "Info.plist", contents / "Info.plist")
    shutil.copytree(NATIVE / "Resources", resources, dirs_exist_ok=True)
    licenses = resources / "Licenses"
    licenses.mkdir(exist_ok=True)
    cxx = output(["xcrun", "--find", "clang++"])
    swift = output(["xcrun", "--find", "swiftc"])
    optimization = ["-O2", "-DNDEBUG"] if args.configuration == "release" else ["-O0", "-g"]
    objects = []
    engine_sources = sorted(list((NATIVE / "Engine").rglob("*.mm")) + list((NATIVE / "Engine").rglob("*.cpp")))
    if not engine_sources:
        parser.error("No native engine sources found.")
    for source in engine_sources:
        obj = objects_dir / (source.stem + "-" + hashlib.sha256(str(source).encode()).hexdigest()[:8] + ".o")
        command = [cxx, "-std=c++20", "-arch", "arm64", f"-mmacosx-version-min={MINIMUM_MACOS}",
                   "-isysroot", sdk, "-Wall", "-Wextra", *optimization, *cflags]
        if source.suffix == ".mm":
            command.append("-fobjc-arc")
        run([*command, "-c", source, "-o", obj])
        objects.append(obj)
    swift_sources = sorted((NATIVE / "App").rglob("*.swift"))
    swift_optimization = ["-O"] if args.configuration == "release" else ["-Onone", "-g"]
    run([swift, "-swift-version", "5", "-target", "arm64-apple-macosx27.0", "-sdk", sdk,
         "-module-name", "CBittorrent", *swift_optimization,
         "-import-objc-header", NATIVE / "Engine/CBTEngine.h", *swift_sources, *objects,
         *libs, "-lc++", "-framework", "Cocoa", "-framework", "CoreText",
         "-framework", "UserNotifications", "-Xlinker", "-headerpad_max_install_names",
         "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks", "-o", executable])
    search_paths = [flag[2:] for flag in libs if flag.startswith("-L")]
    sources = package_libraries(executable, frameworks, search_paths)
    copy_licenses(sources, licenses)
    provenance = {
        "macOSDeploymentTarget": MINIMUM_MACOS, "architecture": "arm64",
        "sdk": sdk_version, "libtorrent": version,
        "dependencies": [{"name": destination.name, "source": str(source),
                          "sha256": hashlib.sha256(source.read_bytes()).hexdigest()}
                         for source, destination in sources.items() if destination != executable]
    }
    (resources / "build-info.json").write_text(json.dumps(provenance, indent=2) + "\n")
    for library in sorted(frameworks.iterdir()):
        run(["codesign", "--force", "--sign", "-", library])
    run(["codesign", "--force", "--sign", "-", app])
    run([sys.executable, NATIVE / "scripts/audit_no_qt.py", app])
    run(["codesign", "--verify", "--deep", "--strict", app])
    print(f"\nBuilt {app}\nOpen with: open {shlex.quote(str(app))}")


if __name__ == "__main__":
    try:
        main()
    except (subprocess.CalledProcessError, RuntimeError) as error:
        sys.exit(str(error))
