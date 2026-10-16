#!/usr/bin/env python3
"""Address discovery, lightweight rule selection and bounded alert reading."""
import ipaddress
from datetime import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def local_networks():
    networks = set()
    commands = (["ip", "-j", "address", "show"], ["ip", "-j", "route", "show", "table", "all"],
                ["ip", "-j", "-6", "route", "show", "table", "all"])
    for index, command in enumerate(commands):
        rows = json.loads(subprocess.check_output(command, text=True, timeout=10))
        for row in rows:
            addresses = [item["local"] for item in row.get("addr_info", []) if "local" in item] if index == 0 else [row.get("prefsrc")]
            for value in addresses:
                if not value:
                    continue
                address = ipaddress.ip_address(value.split("%", 1)[0])
                if not (address.is_unspecified or address.is_multicast):
                    networks.add(f"{address}/{address.max_prefixlen}")
    if not networks:
        raise ValueError("No local addresses detected; refusing an empty HOME_NET")
    return "[" + ",".join(sorted(networks)) + "]"


def atomic_write(path, data):
    path = Path(path)
    fd, temporary = tempfile.mkstemp(prefix=".ips-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, 0o640)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def engine_major():
    output = subprocess.check_output(["suricata", "-V"], text=True, timeout=10)
    match = re.search(r"(?:version\s+|Suricata\s+)(\d+)\.", output, re.IGNORECASE)
    if not match or int(match[1]) < 6:
        raise ValueError("Suricata 6 or newer is required")
    return int(match[1])


def configure(source, destination, refresh=False):
    import yaml
    with open(source, encoding="utf-8") as handle:
        config = yaml.safe_load(handle)
    if not isinstance(config, dict):
        raise ValueError("Invalid Suricata configuration")
    groups = config.setdefault("vars", {}).setdefault("address-groups", {})
    home = local_networks()
    if refresh and home == groups.get("HOME_NET"):
        return False
    groups.update(HOME_NET=home, EXTERNAL_NET="!$HOME_NET")
    if not refresh:
        config.update({"default-rule-path": "/var/lib/marzban-ips/rules",
                       "rule-files": ["suricata.rules"], "exception-policy": "ignore",
                       "max-pending-packets": 256, "runmode": "workers"})
        config["nfq"] = {"mode": "accept", "fail-open": True, "batchcount": 20}
        config["flow"] = {"memcap": "32mb", "hash-size": 16384, "prealloc": 1000, "memcap-policy": "pass-packet"}
        config["stream"] = {"memcap": "32mb", "prealloc-sessions": 512, "inline": True,
                            # Drop selected signatures, not TCP state validation failures.
                            "drop-invalid": False,
                            "midstream": True, "midstream-policy": "ignore", "memcap-policy": "pass-flow",
                            "reassembly": {"memcap": "64mb", "depth": "256kb", "memcap-policy": "pass-flow"}}
        config.setdefault("defrag", {}).update({"memcap": "16mb", "memcap-policy": "pass-packet"})
        config.setdefault("app-layer", {})["error-policy"] = "ignore"
        config["outputs"] = [{"eve-log": {"enabled": True, "filetype": "regular", "filename": "eve.json",
            "types": [{"alert": {"payload": False, "payload-printable": False, "packet": False,
                                 "metadata": False, "http-body": False, "http-body-printable": False}},
                      {"stats": {"totals": True, "threads": False}}]}}]
        config["stats"] = {"enabled": True, "interval": 10}
        config["logging"] = {"default-log-level": "notice", "outputs": [{"console": {"enabled": True}}]}
        config["unix-command"] = {"enabled": False}
        config.setdefault("detect", {})["profile"] = "low"
        config.pop("run-as", None)
        config.pop("daemon", None)
        if engine_major() < 7:
            # Older 6.x builds predate exception policies and already fail open.
            config.pop("exception-policy", None)
            for section in (config["flow"], config["stream"], config["stream"]["reassembly"], config["defrag"], config["app-layer"]):
                for key in ("memcap-policy", "midstream-policy", "error-policy"):
                    section.pop(key, None)
    atomic_write(destination, "%YAML 1.1\n---\n" + yaml.safe_dump(config, sort_keys=False))
    return True


MESSAGE = re.compile(r'\bmsg:"((?:[^"\\]|\\.)*)"')
SELECTED = re.compile(r"(?:^ET (?:BOTCC|CNC)\b|\b(?:Andromeda|Avalanche)\b)", re.IGNORECASE)
SID = re.compile(r"\bsid:\s*(\d+)\s*;")
FLOWBITS = re.compile(r"\bflowbits:\s*(isset|isnotset|set|unset|toggle)\s*,\s*([^;]+);")


def bit_names(line, operations):
    return {name.strip() for operation, names in FLOWBITS.findall(line) if operation in operations
            for name in re.split(r"[&|]", names) if name.strip()}


def select_rules(source, destination, selftest):
    selected, seen, candidates = [], set(), {}
    with open(source, encoding="utf-8") as handle:
        for line in handle:
            if len(line) > 1024 * 1024:
                raise ValueError("Oversized rule")
            if not line.startswith(("alert ", "drop ")):
                continue
            message, sid = MESSAGE.search(line), SID.search(line)
            if not message or not sid:
                continue
            if sid[1] in candidates:
                raise ValueError("Duplicate SID in feed")
            candidates[sid[1]] = line
            if SELECTED.search(message[1]):
                if sid[1] in seen or sid[1] == "9900001":
                    raise ValueError("Duplicate or reserved SID in selected feed")
                seen.add(sid[1])
    if not seen:
        raise ValueError("No selected malware/C2 signatures; keeping the previous rules")
    included = set(seen)
    # Retain prerequisite flowbit setters; a filtered rule must not lose its state.
    while True:
        required = set().union(*(bit_names(candidates[sid], {"isset", "isnotset"}) for sid in included))
        dependencies = {sid for sid, line in candidates.items() if bit_names(line, {"set", "unset", "toggle"}) & required}
        if dependencies <= included:
            break
        included.update(dependencies)
    if "9900001" in included:
        raise ValueError("Feed uses the reserved self-test SID")
    for sid in sorted(included, key=int):
        action = "drop" if sid in seen else "alert"
        selected.append(action + " " + candidates[sid].split(" ", 1)[1].rstrip() + "\n")
    with open(selftest, encoding="utf-8") as handle:
        selected.append(handle.read().rstrip() + "\n")
    atomic_write(destination, "".join(selected))
    print(f"Selected {len(seen)} malware/C2 rules, {len(included - seen)} supporting rules and one harmless self-test")


def events(path, token=None, started=None):
    with open(path, "rb") as handle:
        handle.seek(0, os.SEEK_END)
        handle.seek(max(0, handle.tell() - 8 * 1024 * 1024))
        if handle.tell():
            handle.readline()
        lines = handle.read(8 * 1024 * 1024).splitlines()
    results = []
    for line in lines:
        try:
            event = json.loads(line)
        except (ValueError, UnicodeError):
            continue
        alert = event.get("alert", {})
        if event.get("event_type") != "alert" or not (alert.get("action") == "blocked" or event.get("verdict", {}).get("action") == "drop"):
            continue
        if token:
            try:
                timestamp = datetime.fromisoformat(event["timestamp"].replace("Z", "+00:00")).timestamp()
            except (KeyError, ValueError, TypeError):
                continue
            if (alert.get("signature_id") == 9900001 and str(event.get("src_port")) == token
                    and event.get("dest_port") == 80 and timestamp >= float(started)):
                return True
        else:
            results.append(f"{event.get('timestamp')} {event.get('src_ip')}:{event.get('src_port')} -> "
                           f"{event.get('dest_ip')}:{event.get('dest_port')} SID={alert.get('signature_id')} {alert.get('signature')}")
    if not token:
        print("\n".join(results[-50:]) or "No recent blocked events")
    return False


if __name__ == "__main__":
    try:
        action, *args = sys.argv[1:]
        if action in ("configure", "refresh"):
            changed = configure(*args, refresh=action == "refresh")
            if action == "refresh":
                print("changed" if changed else "unchanged")
        elif action == "select":
            select_rules(*args)
        elif action == "events":
            events(*args)
        elif action == "test-event":
            sys.exit(0 if events(*args) else 1)
        else:
            raise ValueError("Unknown action")
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
