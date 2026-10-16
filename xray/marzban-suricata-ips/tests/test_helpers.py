"""Offline regression tests. Run with python3 -m unittest discover -s tests -v."""
from contextlib import redirect_stdout
from datetime import datetime, timezone
import importlib.util
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("ips_helpers", ROOT / "ips_helpers.py")
HELPERS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HELPERS)


class HelpersTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)

    def rule(self, sid, message, extra="", action="alert"):
        return f'{action} tcp $HOME_NET any -> $EXTERNAL_NET any (msg:"{message}"; {extra} sid:{sid}; rev:1;)\n'

    def test_stream_errors_do_not_drop_while_signature_ips_stays_enabled(self):
        # Exercise generation without depending on the YAML serializer/toolchain.
        source, destination = self.directory / "base", self.directory / "generated"
        source.write_text("fixture", encoding="utf-8")
        captured = {}

        def dump(config, **kwargs):
            captured.update(config)
            return json.dumps(config)

        serializer = SimpleNamespace(safe_load=lambda handle: {"vars": {}}, safe_dump=dump)
        for major in (6, 7, 8):
            with self.subTest(major=major), patch.dict(sys.modules, {"yaml": serializer}), \
                    patch.object(HELPERS, "local_networks", return_value="[10.0.0.4/32]"), \
                    patch.object(HELPERS, "engine_major", return_value=major):
                HELPERS.configure(source, destination)
                self.assertIs(captured["stream"].get("drop-invalid"), False)
                self.assertIs(captured["stream"]["inline"], True)
                self.assertEqual(captured["rule-files"], ["suricata.rules"])

    def select(self, text):
        source, destination = self.directory / "source", self.directory / "rules"
        source.write_text(text, encoding="utf-8")
        with redirect_stdout(io.StringIO()):
            HELPERS.select_rules(source, destination, ROOT / "selftest.rules")
        return destination.read_text(encoding="utf-8")

    def test_multiple_addresses_floating_route_and_ipv6(self):
        values = [json.dumps([{"addr_info": [{"local": "10.0.0.4"}, {"local": "203.0.113.4"},
                                              {"local": "2001:db8::4"}, {"local": "10.0.0.4"}]}]),
                  json.dumps([{"prefsrc": "198.51.100.9"}]), "[]"]
        with patch.object(HELPERS.subprocess, "check_output", side_effect=values) as check:
            networks = HELPERS.local_networks()
        self.assertEqual(networks, "[10.0.0.4/32,198.51.100.9/32,2001:db8::4/128,203.0.113.4/32]")
        self.assertEqual(check.call_count, 3)

    def test_no_addresses_aborts(self):
        with patch.object(HELPERS.subprocess, "check_output", return_value="[]"):
            with self.assertRaisesRegex(ValueError, "No local addresses"):
                HELPERS.local_networks()

    def test_engine_version_detection(self):
        for major in (6, 7, 8):
            with patch.object(HELPERS.subprocess, "check_output", return_value=f"This is Suricata version {major}.0.4 RELEASE"):
                self.assertEqual(HELPERS.engine_major(), major)
        with patch.object(HELPERS.subprocess, "check_output", return_value="Suricata version 5.0.0"):
            with self.assertRaises(ValueError):
                HELPERS.engine_major()

    def test_only_selected_messages_drop_and_disabled_stays_disabled(self):
        result = self.select(self.rule(1, "ET CNC Test") + self.rule(2, "Normal browsing")
                             + "# " + self.rule(3, "ET BOTCC Disabled") + self.rule(4, "ET POLICY Test", action="pass"))
        self.assertIn("drop tcp", result)
        self.assertIn("sid:1;", result)
        self.assertNotIn("sid:2;", result)
        self.assertNotIn("sid:3;", result)
        self.assertNotIn("sid:4;", result)
        self.assertEqual(result.count("sid:9900001;"), 1)

    def test_empty_selection_does_not_overwrite_existing_rules(self):
        destination = self.directory / "rules"
        destination.write_text("previous", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "No selected"):
            self.select(self.rule(1, "Ordinary rule"))
        self.assertEqual(destination.read_text(), "previous")

    def test_duplicate_and_reserved_sid_abort(self):
        for text in [self.rule(1, "ET CNC A") + self.rule(1, "ET CNC B"), self.rule(9900001, "ET CNC Reserved")]:
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.select(text)

    def test_transitive_flowbit_dependencies_do_not_become_drop(self):
        text = self.rule(1, "ET CNC Final", "flowbits:isset,stage2;")
        text += self.rule(2, "Helper 2", "flowbits:set,stage2; flowbits:isset,stage1;")
        text += self.rule(3, "Helper 1", "flowbits:set,stage1; flowbits:noalert;")
        text += self.rule(4, "Unrelated", "flowbits:set,other;")
        result = self.select(text)
        lines = result.splitlines()
        self.assertTrue(next(line for line in lines if "sid:1;" in line).startswith("drop "))
        self.assertTrue(next(line for line in lines if "sid:2;" in line).startswith("alert "))
        self.assertTrue(next(line for line in lines if "sid:3;" in line).startswith("alert "))
        self.assertNotIn("sid:4;", result)

    def test_selftest_requires_fresh_matching_blocked_tuple(self):
        log = self.directory / "eve.json"
        epoch = 1700000000.0
        event = {"timestamp": datetime.fromtimestamp(epoch, timezone.utc).isoformat(),
                 "event_type": "alert", "src_port": 41000, "dest_port": 80,
                 "alert": {"signature_id": 9900001, "action": "blocked"}}
        log.write_text("{partial}\n" + json.dumps(event) + "\n{unfinished", encoding="utf-8")
        self.assertTrue(HELPERS.events(log, "41000", str(epoch - 1)))
        self.assertFalse(HELPERS.events(log, "41000", str(epoch + 0.1)))
        self.assertFalse(HELPERS.events(log, "41001", str(epoch - 1)))
        event["alert"]["action"] = "allowed"
        log.write_text(json.dumps(event), encoding="utf-8")
        self.assertFalse(HELPERS.events(log, "41000", str(epoch - 1)))

    @unittest.skipUnless(importlib.util.find_spec("yaml"), "PyYAML is required for configuration integration")
    def test_configuration_disables_payload_and_preserves_base(self):
        import yaml
        source, destination = self.directory / "base.yaml", self.directory / "generated.yaml"
        original = "vars: {}\noutputs: []\nstream: {}\n"
        source.write_text(original, encoding="utf-8")
        with patch.object(HELPERS, "local_networks", return_value="[10.0.0.4/32,2001:db8::4/128]"), patch.object(HELPERS, "engine_major", return_value=7):
            HELPERS.configure(source, destination)
            before = destination.read_bytes()
            self.assertFalse(HELPERS.configure(destination, destination, refresh=True))
            self.assertEqual(destination.read_bytes(), before)
        config = yaml.safe_load(destination.read_text())
        self.assertEqual(source.read_text(), original)
        self.assertTrue(config["nfq"]["fail-open"])
        self.assertEqual(config["exception-policy"], "ignore")
        self.assertFalse(config["stream"]["drop-invalid"])
        self.assertFalse(config["outputs"][0]["eve-log"]["types"][0]["alert"]["payload"])
        self.assertEqual(config["rule-files"], ["suricata.rules"])
        with patch.object(HELPERS, "local_networks", return_value="[198.51.100.9/32]"):
            self.assertTrue(HELPERS.configure(destination, destination, refresh=True))
        self.assertEqual(yaml.safe_load(destination.read_text())["vars"]["address-groups"]["HOME_NET"], "[198.51.100.9/32]")


if __name__ == "__main__":
    unittest.main()
