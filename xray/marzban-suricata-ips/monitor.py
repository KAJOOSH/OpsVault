#!/usr/bin/env python3
"""Live, read-only node/inspection telemetry; no packet capture or payload storage."""
import argparse
from collections import deque
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

EVE = Path("/var/log/marzban-suricata/eve.json")


def timestamp(value):
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError):
        return 0


def command(arguments):
    try:
        result = subprocess.run(arguments, capture_output=True, text=True, timeout=3, check=False)
        return result.stdout if result.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        return None


def number(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def text_file(path, default=""):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return default


def interfaces(text):
    result = {}
    for line in text.splitlines()[2:]:
        if ":" not in line:
            continue
        name, counters = line.rsplit(":", 1)
        fields = counters.split()
        if len(fields) >= 16 and name.strip() != "lo":
            result[name.strip()] = {"rx": int(fields[0]), "tx": int(fields[8]),
                                    "errors": sum(int(fields[index]) for index in (2, 3, 10, 11))}
    return result


def nft_counters(document):
    counters = {}
    for entry in document.get("nftables", []):
        rule = entry.get("rule", {})
        label = rule.get("comment")
        if not label:
            label = {"egress": "ips-egress", "ingress_replies": "ips-ingress"}.get(rule.get("chain"))
        if label:
            for expression in rule.get("expr", []):
                if "counter" in expression:
                    counters[label] = expression["counter"]
    return counters


class EventReader:
    def __init__(self, path=EVE):
        self.path = Path(path)
        self.identity = None
        self.offset = 0
        self.prefix = b""
        self.pending = b""
        self.stats = None
        self.stats_time = 0
        self.alerts = deque(maxlen=5)
        self.limited = False
        self.observed_packets = None
        self.stalled_since = None

    def poll(self):
        try:
            with self.path.open("rb") as handle:
                state = os.fstat(handle.fileno())
                identity = (state.st_dev, state.st_ino)
                prefix = handle.read(64)
                reset = identity != self.identity or state.st_size < self.offset or (self.prefix and not prefix.startswith(self.prefix))
                if reset:
                    self.offset = max(0, state.st_size - 256 * 1024)
                    self.pending = b""
                self.limited = state.st_size - self.offset > 512 * 1024
                if self.limited:
                    self.offset = max(0, state.st_size - 256 * 1024)
                    self.pending = b""
                handle.seek(self.offset)
                if (reset or self.limited) and self.offset:
                    handle.readline()
                data = self.pending + handle.read(512 * 1024)
                self.offset = handle.tell()
                self.identity, self.prefix = identity, prefix
        except OSError:
            return
        lines = data.split(b"\n")
        self.pending = lines.pop()[-65536:]
        for line in lines:
            try:
                event = json.loads(line)
            except (ValueError, UnicodeError):
                continue
            if not isinstance(event, dict):
                continue
            if event.get("event_type") == "stats":
                self.stats = event.get("stats", {})
                self.stats_time = timestamp(event.get("timestamp"))
            elif event.get("event_type") == "alert":
                self.alerts.append(event)


def delta(current, previous, seconds):
    if current is None or previous is None or seconds <= 0 or current < previous:
        return None
    return (current - previous) / seconds


def drop_breakdown(stats):
    ips = stats.get("ips", {})
    total = number(ips.get("blocked"))
    raw = ips.get("drop_reason", {})
    reasons = {key: count for key, value in raw.items() if (count := number(value)) is not None and count >= 0}
    rules = reasons.get("rules")
    other = max(0, total - (rules or 0)) if total is not None else sum(count for key, count in reasons.items() if key != "rules")
    return total, rules, other, reasons


def health(active, table, bound, stats_age, packets, recent_alerts, new_drops=0, queued=0, stalled=False, engine_other_drops=0):
    if active is None:
        return "WARNING", "Cannot read the engine state; inspection is not confirmed."
    if not active:
        return "OFF", "Inspection engine is stopped. Traffic is not inspected."
    if not table or not bound:
        return "WARNING", "Inspection path is incomplete; check engine, queue and firewall."
    if stats_age is None or stats_age > 45:
        return "WAITING", "No fresh engine statistics; inspection is not yet confirmed."
    if new_drops or queued >= 128:
        return "WARNING", "Queue pressure or loss detected; inspection may be delayed or bypassed."
    if stalled:
        return "WARNING", "Traffic is reaching the queue but engine packet counters are not progressing."
    if engine_other_drops:
        return "WARNING", "Engine drops outside direct rule matches are recorded since start; inspect the reasons below."
    if recent_alerts:
        return "ALERT", "Recent rule matches detected. Review the events below."
    if not packets:
        return "IDLE", "Engine is reporting; waiting for observed traffic."
    return "RUNNING", "Engine has processed traffic. No recent threat alerts in the visible log."


def sample():
    properties = command(["systemctl", "show", "marzban-suricata.service", "--no-pager",
                          "-p", "ActiveState", "-p", "MemoryCurrent", "-p", "CPUUsageNSec"])
    service = dict(line.split("=", 1) for line in (properties or "").splitlines() if "=" in line)
    firewall = command(["nft", "-j", "list", "table", "inet", "marzban_ips"])
    try:
        counters = nft_counters(json.loads(firewall)) if firewall is not None else {}
    except (ValueError, TypeError, AttributeError):
        counters, firewall = {}, None
    queue = text_file("/etc/marzban-ips/queue-number")
    queues = []
    for line in text_file("/proc/net/netfilter/nfnetlink_queue").splitlines():
        fields = line.split()
        if len(fields) >= 7 and number(fields[0]) == number(queue):
            queues.append(fields)
    dropped = sum(int(row[5]) + int(row[6]) for row in queues)
    try:
        network = interfaces(text_file("/proc/net/dev"))
    except ValueError:
        network = {}
    return {"time": time.monotonic(), "service": service,
            "table": firewall is not None and {"ips-egress", "ips-ingress"} <= counters.keys(), "counters": counters,
            "network": network, "bound": any(number(row[1]) for row in queues),
            "queued": sum(int(row[2]) for row in queues), "queue_drops": dropped}


def readable(value, unit=""):
    return "unavailable" if value is None else f"{value:,.1f}{unit}"


def safe(value):
    return re.sub(r"[\x00-\x1f\x7f-\x9f]", "", str(value))[:180]


def render(current, previous, reader):
    now = time.time()
    elapsed = current["time"] - previous["time"] if previous else 0
    service = current["service"]
    cpu = delta(number(service.get("CPUUsageNSec")), number(previous["service"].get("CPUUsageNSec")) if previous else None, elapsed)
    memory = number(service.get("MemoryCurrent"))
    stats = reader.stats or {}
    processed = number(stats.get("decoder", {}).get("pkts"))
    blocked, rule_drops, other_drops, reasons = drop_breakdown(stats)
    reason_text = "rules=" + (str(rule_drops) if rule_drops is not None else "unavailable")
    reason_text += "".join(f"  {safe(key)}={value}" for key, value in sorted(reasons.items()) if key != "rules" and value)
    if blocked is not None and blocked > sum(reasons.values()):
        reason_text += f"  unattributed={blocked - sum(reasons.values())}"
    recent = [event for event in reader.alerts if 0 <= now - timestamp(event.get("timestamp")) <= 300
              and event.get("alert", {}).get("signature_id") != 9900001]
    loss = max(0, current["queue_drops"] - previous["queue_drops"]) if previous else 0
    age = max(0, now - reader.stats_time) if reader.stats_time else None
    offered = 0
    for label in ("ips-egress", "ips-ingress"):
        count = current["counters"].get(label, {}).get("packets")
        old_count = previous["counters"].get(label, {}).get("packets") if previous else None
        if count is not None and old_count is not None:
            offered += max(0, count - old_count)
    if offered and processed is not None and processed == reader.observed_packets:
        if reader.stalled_since is None:
            reader.stalled_since = time.monotonic()
    else:
        reader.stalled_since = None
    reader.observed_packets = processed
    stalled = reader.stalled_since is not None and time.monotonic() - reader.stalled_since > 30
    active = service["ActiveState"] == "active" if "ActiveState" in service else None
    state, explanation = health(active, current["table"], current["bound"], age, processed, recent, loss, current["queued"], stalled, other_drops)
    version = text_file("/etc/marzban-ips/version", "2.0 (legacy)")
    available_memory = None
    for line in text_file("/proc/meminfo").splitlines():
        if line.startswith("MemAvailable:"):
            available_memory = number(line.split()[1])
    lines = [f"Marzban IPS {safe(version)}  |  {datetime.now().astimezone():%Y-%m-%d %H:%M:%S %Z}",
             f"{state}: {explanation}", "",
             f"Engine CPU: {readable(cpu / 10000000 if cpu is not None else None, '% of one core')}  "
             f"RAM: {readable(memory / 1048576 if memory is not None else None, ' MiB')}",
             f"Node load (1/5/15 min): {text_file('/proc/loadavg').rsplit(' ', 2)[0]}",
             f"Node available RAM: {readable(available_memory / 1024 if available_memory is not None else None, ' MiB')}",
             f"Rules last checked: {safe(text_file('/var/lib/marzban-ips/rules-checked-at', 'not recorded'))}",
             f"Queue waiting: {current['queued']}  queue loss since start: {current['queue_drops']}  new loss: {loss}",
             f"Engine packets since start: {processed if processed is not None else 'unavailable'}  "
             f"blocked packets: {blocked if blocked is not None else 'unavailable'}  "
             f"stats age: {readable(age, 's')}",
             f"Engine drop reasons since start: {reason_text}",
             f"Signature alerts since start: {stats.get('detect', {}).get('alert', 'unavailable')}",
             "Blocked packets are not a count of malware detections.",
             "", "Interface traffic (separate interfaces; not summed):", "  Interface        IN Mbps       OUT Mbps"]
    for name, values in sorted(current["network"].items())[:12]:
        old = previous["network"].get(name, {}) if previous else {}
        rx, tx = delta(values["rx"], old.get("rx"), elapsed), delta(values["tx"], old.get("tx"), elapsed)
        lines.append(f"  {safe(name):<16} {readable(rx * 8 / 1e6 if rx is not None else None):>10} "
                     f"{readable(tx * 8 / 1e6 if tx is not None else None):>14}")
    labels = {"client-ingress": "Inbound connections -> node (counted only)",
              "client-egress": "Node replies -> inbound clients (counted only)",
              "ips-egress": "Node -> destinations (queued for inspection)",
              "ips-ingress": "Destination replies -> node (queued for inspection)"}
    lines.extend(["", "Traffic paths (queue counters count offered packets, including bypass):"])
    for label, description in labels.items():
        value = current["counters"].get(label, {})
        old = previous["counters"].get(label, {}) if previous else {}
        rate = delta(value.get("bytes"), old.get("bytes"), elapsed)
        lines.append(f"  {description}: {readable(rate * 8 / 1e6 if rate is not None else None, ' Mbps')}")
    lines.extend(["", "Recent events (last 5 visible alerts):"])
    for event in reader.alerts:
        alert = event.get("alert", {})
        action = "BLOCKED" if alert.get("action") == "blocked" or event.get("verdict", {}).get("action") == "drop" else "ALERT"
        label = "SELF-CHECK" if alert.get("signature_id") == 9900001 else action
        lines.append(f"  {safe(event.get('timestamp'))} {label} {safe(event.get('src_ip'))} -> "
                     f"{safe(event.get('dest_ip'))} SID={alert.get('signature_id')} {safe(alert.get('signature'))}")
    if not reader.alerts:
        lines.append("  No recent visible alerts. This does not establish that traffic is malware-free.")
    if reader.limited:
        lines.append("WARNING: log backlog exceeded the live-view limit; only the newest records are shown.")
    lines.extend(["", "RUNNING confirms engine activity, not complete threat coverage or VPN connectivity.",
                  "Exit live view: Ctrl+C (inspection continues)."])
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Read-only live node and IPS traffic monitor")
    parser.add_argument("--once", action="store_true", help="show one status report")
    parser.add_argument("--interval", type=float, default=2, help="refresh interval, 1..60 seconds")
    args = parser.parse_args()
    if not 1 <= args.interval <= 60:
        parser.error("interval must be between 1 and 60 seconds")
    reader = EventReader()
    previous = sample()
    reader.poll()
    while True:
        time.sleep(1 if args.once else args.interval)
        current = sample()
        reader.poll()
        if sys.stdout.isatty() and not args.once:
            print("\033[2J\033[H", end="")
        print(render(current, previous, reader), flush=True)
        if args.once:
            return
        previous = current


if __name__ == "__main__":
    try:
        main()
    except (KeyboardInterrupt, BrokenPipeError):
        pass
