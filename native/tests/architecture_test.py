#!/usr/bin/env python3
"""Guard the dependency direction of the native application in CI."""
from pathlib import Path
import re
import unittest

APP = Path(__file__).resolve().parents[1] / "App"


class ArchitectureTests(unittest.TestCase):
    def test_inner_layers_have_no_platform_or_adapter_dependencies(self):
        adapters = ("EngineService", "JSONSettingsRepository", "LocalDownloadDirectory",
                    "SystemCompletionNotifier", "AppComposition", "AppStore", "FileSystemService")
        for layer in ("Domain", "Application"):
            for path in (APP / layer).glob("*.swift"):
                text = path.read_text()
                with self.subTest(path=path.name):
                    self.assertEqual(set(re.findall(r"^import (\w+)", text, re.M)) - {"Foundation"}, set())
                    self.assertNotRegex(text, r"\b(?:" + "|".join(adapters) + r"|cbt_\w+)\b")
                    self.assertNotRegex(text, r"\b(?:Data\(contentsOf:|UserDefaults|NSWorkspace)")

    def test_c_bridge_is_confined_to_engine_adapter(self):
        for path in APP.rglob("*.swift"):
            if path == APP / "Infrastructure/EngineService.swift":
                continue
            with self.subTest(path=path.name):
                self.assertNotRegex(path.read_text(), r"\bcbt_\w+")

    def test_presentation_uses_application_not_engine_or_settings_storage(self):
        text = (APP / "UI/AppStore.swift").read_text()
        self.assertNotRegex(text, r"\b(?:EngineService|TransferEngine|FileManager|JSONEncoder|JSONDecoder|UserNotifications)\b")
        self.assertIn("TransferApplication", text)


if __name__ == "__main__":
    unittest.main()
