from datetime import datetime, timezone
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


MONITOR, UPDATE = load("monitor"), load("project_update")


class MonitorTests(unittest.TestCase):
    def test_reported_stream_error_drops_are_not_shown_as_running_clean(self):
        reader = MONITOR.EventReader()
        reader.stats_time = time.time()
        reader.stats = {"decoder": {"pkts": 3528326}, "detect": {"alert": 0},
                        "ips": {"accepted": 3524061, "blocked": 4265,
                                "drop_reason": {"rules": 0, "stream_error": 4265}}}
        current = {"time": 2, "service": {"ActiveState": "active", "CPUUsageNSec": "1", "MemoryCurrent": "1"},
                   "table": True, "bound": True, "queued": 0, "queue_drops": 0,
                   "counters": {}, "network": {}}
        with patch.object(MONITOR, "text_file", return_value=""):
            report = MONITOR.render(current, dict(current, time=1), reader)
        self.assertIn("WARNING:", report)
        self.assertIn("stream_error=4265", report)
        self.assertIn("rules=0", report)

    def test_unknown_or_stale_statistics_never_show_running(self):
        for age in (None, 46, 600):
            self.assertEqual(MONITOR.health(True, True, True, age, 99, [])[0], "WAITING")
        self.assertEqual(MONITOR.health(True, False, True, 1, 99, [])[0], "WARNING")
        self.assertEqual(MONITOR.health(True, True, False, 1, 99, [])[0], "WARNING")
        self.assertEqual(MONITOR.health(None, True, True, 1, 99, [])[0], "WARNING")
        self.assertEqual(MONITOR.health(True, True, True, 1, 99, [], queued=128)[0], "WARNING")
        self.assertEqual(MONITOR.health(True, True, True, 1, 99, [], stalled=True)[0], "WARNING")

    def test_off_idle_threat_and_queue_pressure(self):
        self.assertEqual(MONITOR.health(False, True, True, 1, 99, [])[0], "OFF")
        self.assertEqual(MONITOR.health(True, True, True, 1, 0, [])[0], "IDLE")
        self.assertEqual(MONITOR.health(True, True, True, 1, 99, [1])[0], "ALERT")
        self.assertEqual(MONITOR.health(True, True, True, 1, 99, [], 1)[0], "WARNING")
        self.assertEqual(MONITOR.health(True, True, True, 1, 99, [])[0], "RUNNING")

    def test_counter_resets_and_missing_data_are_unknown(self):
        self.assertIsNone(MONITOR.delta(2, 10, 2))
        self.assertIsNone(MONITOR.delta(None, 10, 2))
        self.assertEqual(MONITOR.delta(30, 10, 2), 10)

    def test_log_partial_records_rotation_and_copytruncate(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "eve.json"
            event = {"timestamp": datetime.now(timezone.utc).isoformat(), "event_type": "stats", "stats": {"decoder": {"pkts": 20}}}
            payload = json.dumps(event).encode()
            log.write_bytes(payload[:50])
            reader = MONITOR.EventReader(log)
            reader.poll()
            self.assertIsNone(reader.stats)
            with log.open("ab") as handle:
                handle.write(payload[50:] + b"\n")
            reader.poll()
            self.assertEqual(reader.stats["decoder"]["pkts"], 20)
            event["stats"]["decoder"]["pkts"] = 1
            log.rename(Path(directory) / "old")
            log.write_text(json.dumps(event) + "\n")
            reader.poll()
            self.assertEqual(reader.stats["decoder"]["pkts"], 1)
            event["stats"]["decoder"]["pkts"] = 30
            event["timestamp"] = "2026-10-16T00:00:00Z"
            log.write_text(json.dumps(event) + "\n")
            reader.poll()
            self.assertEqual(reader.stats["decoder"]["pkts"], 30)

    def test_nft_path_counters_and_terminal_escapes(self):
        counters = MONITOR.nft_counters({"nftables": [{"rule": {"comment": "ips-egress", "expr": [{"counter": {"packets": 3, "bytes": 40}}]}}]})
        self.assertEqual(counters["ips-egress"]["packets"], 3)
        self.assertNotIn("\033", MONITOR.safe("bad\033[2J"))


class UpdateBundleTests(unittest.TestCase):
    SHA = "a" * 40

    def archive(self, path, malicious=None):
        prefix = f"OpsVault-{self.SHA}/xray/marzban-suricata-ips/"
        with tarfile.open(path, "w:gz") as archive:
            for name in UPDATE.FILES:
                info = tarfile.TarInfo(prefix + name)
                data = b"2.1.0\n" if name == "VERSION" else b"fixture\n"
                info.size = len(data)
                if malicious == name:
                    info.type = tarfile.SYMTYPE
                    info.linkname = "/etc/passwd"
                    info.size = 0
                    archive.addfile(info)
                else:
                    archive.addfile(info, io.BytesIO(data))

    def test_complete_pinned_snapshot_extracts_expected_files(self):
        with tempfile.TemporaryDirectory() as directory:
            stage = Path(directory)
            self.archive(stage / "bundle.tgz")
            self.assertEqual(UPDATE.extract_bundle(stage / "bundle.tgz", stage, self.SHA), "2.1.0")
            self.assertTrue((stage / "upgrade.sh").is_file())

    def test_symlink_missing_bundle_and_untrusted_commit_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            stage = Path(directory)
            self.archive(stage / "bundle.tgz", malicious="install.sh")
            with self.assertRaises(ValueError):
                UPDATE.extract_bundle(stage / "bundle.tgz", stage, self.SHA)
            with self.assertRaises(ValueError):
                UPDATE.extract_bundle(stage / "bundle.tgz", stage, "../main")
            with tarfile.open(stage / "empty.tgz", "w:gz"):
                pass
            with self.assertRaises(ValueError):
                UPDATE.extract_bundle(stage / "empty.tgz", stage, self.SHA)

    def test_semantic_versions_order_numerically(self):
        self.assertGreater(UPDATE.version("2.10.0"), UPDATE.version("2.9.9"))
        with self.assertRaises(ValueError):
            UPDATE.version("2.1.0; command")
