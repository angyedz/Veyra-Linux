#!/usr/bin/env python3
"""Static safety invariants for the disabled-by-default OTA channel workflow."""
from pathlib import Path
import unittest

try:
    import yaml
except ImportError as error:
    raise SystemExit("py3-yaml is required for the OTA workflow test") from error

WORKFLOW = (Path(__file__).resolve().parents[1] /
            ".github/workflows/ota-channel.yml")


class OTAPublicationPolicy(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = WORKFLOW.read_text()
        cls.data = yaml.load(cls.source, Loader=yaml.BaseLoader)

    def test_release_only_and_opt_in(self):
        self.assertEqual(self.data["on"]["release"]["types"], ["published"])
        publisher = self.data["jobs"]["publish"]
        self.assertIn("vars.VEYRA_OTA_PUBLISH_ENABLED == 'true'",
                      publisher["if"])
        self.assertIn("environment", publisher)
        self.assertEqual(self.data["permissions"]["contents"], "write")

    def test_requires_exact_commit_tests_and_authenticated_metadata(self):
        source = self.source
        for required in ("origin/main", "ci.yml", "iso.yml",
                         "recovery-e2e.yml", "--verify-bundle",
                         "release-info.json.sig", "manifest.json.sig",
                         "ota-channel", "next <= previous",
                         "gh release download"):
            self.assertIn(required, source)
        self.assertNotIn("secrets.", source)
        self.assertNotIn("git push --force", source)
        self.assertNotIn("PRIVATE KEY", source)


if __name__ == "__main__":
    unittest.main()
