#!/usr/bin/env python3
"""Isolated packaging failure, dependency invalidation and loader audit checks."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parents[1] / "scripts" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


build = load("build_native")
audit = load("audit_no_qt")


class PackagingTests(unittest.TestCase):
    def test_failure_preserves_previous_bundle_and_cleans_staging(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            final = root / "CBittorrent.app"
            final.mkdir()
            (final / "marker").write_text("previous")
            with self.assertRaises(RuntimeError):
                with build.build_workspace(root) as staging:
                    (staging / "CBittorrent.app").mkdir()
                    raise RuntimeError("compiler failed")
            self.assertEqual((final / "marker").read_text(), "previous")
            self.assertFalse(list(root.glob(".staging-*")))
            with build.build_workspace(root) as staging:
                app = staging / "CBittorrent.app"
                app.mkdir()
                (app / "marker").write_text("verified")
                build.promote_bundle(app, final)
            self.assertEqual((final / "marker").read_text(), "verified")

    def test_promotion_failure_restores_previous_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            final = root / "CBittorrent.app"
            final.mkdir()
            (final / "marker").write_text("previous")
            with self.assertRaises(FileNotFoundError):
                build.promote_bundle(root / "missing.app", final)
            self.assertEqual((final / "marker").read_text(), "previous")

    def test_object_cache_tracks_headers_commands_and_toolchain(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, header, obj = root / "source.mm", root / "header with space.h", root / "engine.o"
            source.write_text("source")
            header.write_text("first")
            calls = []
            def compile_fake(arguments):
                calls.append(arguments)
                obj.write_bytes(b"object")
                escaped = str(header).replace(" ", "\\ ")
                obj.with_suffix(".d").write_text(f"{obj}: {source} \\\n {escaped}\n")
            with patch.object(build, "run", compile_fake):
                build.cached_compile(["clang", "-O2"], source, obj, "sdk1")
                build.cached_compile(["clang", "-O2"], source, obj, "sdk1")
                self.assertEqual(len(calls), 1)
                header.write_text("second")
                build.cached_compile(["clang", "-O2"], source, obj, "sdk1")
                build.cached_compile(["clang", "-O0"], source, obj, "sdk1")
                build.cached_compile(["clang", "-O0"], source, obj, "sdk2")
                self.assertEqual(len(calls), 4)

    def test_swift_cache_tracks_imports_and_linked_libraries(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, imported, library = root / "main.swift", root / "module.swiftinterface", root / "lib.dylib"
            for path in (source, imported, library):
                path.write_text("first")
            calls = []
            def compile_fake(arguments):
                calls.append(arguments)
                (root / "CBittorrent-unsigned").write_text("executable")
                (root / "main.swift.d").write_text(f"output: {source} {imported}\n")
            with patch.object(build, "run", compile_fake):
                for _ in range(2):
                    build.cached_swift(["swiftc"], [source], [], [library], root, "sdk")
                self.assertEqual(len(calls), 1)
                imported.write_text("changed import")
                build.cached_swift(["swiftc"], [source], [], [library], root, "sdk")
                library.write_text("changed library")
                build.cached_swift(["swiftc"], [source], [], [library], root, "sdk")
                self.assertEqual(len(calls), 3)

    def test_rpath_must_actually_resolve_inside_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory).resolve()
            loader = app / "Contents/MacOS/CBittorrent"
            frameworks = app / "Contents/Frameworks"
            frameworks.mkdir(parents=True)
            library = frameworks / "engine.dylib"
            library.write_bytes(b"fixture")
            with self.assertRaises(RuntimeError):
                audit.resolve_load("@rpath/engine.dylib", loader, loader.parent, [], app)
            self.assertEqual(audit.resolve_load("@rpath/engine.dylib", loader, loader.parent,
                                               [str(frameworks)], app), library)
            with self.assertRaises(RuntimeError):
                audit.resolve_load("/opt/homebrew/engine.dylib", loader, loader.parent, [], app)

    def test_library_minimum_os_cannot_exceed_app(self):
        audit.validate_minimum_os([" minos 26.0"], Path("library"), "27.0")
        audit.validate_minimum_os(["cmd LC_VERSION_MIN_MACOSX", "cmdsize 16", "version 11.0"], Path("library"), "27.0")
        with self.assertRaises(RuntimeError):
            audit.validate_minimum_os([" minos 28.0"], Path("library"), "27.0")
        with self.assertRaises(RuntimeError):
            audit.validate_minimum_os([" minos 26.0"], Path("app"), "27.0", executable=True)


if __name__ == "__main__":
    unittest.main()
