#!/usr/bin/env python3
"""Fetch an immutable GitHub snapshot and upgrade only this owned package."""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tarfile
import tempfile
import urllib.request

REPOSITORY = "KAJOOSH/OpsVault"
FILES = ("VERSION", "install.sh", "upgrade.sh", "project_update.py", "monitor.py", "ips_helpers.py",
         "marzban-ips", "marzban-ips.nft.in", "marzban-suricata.service", "selftest.rules",
         "marzban-ips-filter.service", "marzban-ips-update.service", "marzban-ips-update.timer",
         "marzban-ips-refresh.service", "marzban-ips-refresh.timer", "marzban-ips-logrotate.service",
         "marzban-ips-logrotate.timer", "marzban-ips.logrotate")


def version(value):
    if not re.fullmatch(r"\d+\.\d+\.\d+", value):
        raise ValueError("Invalid package version")
    return tuple(map(int, value.split(".")))


def download(url, destination, limit):
    request = urllib.request.Request(url, headers={"User-Agent": "OpsVault-Marzban-IPS", "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(request, timeout=30) as response, open(destination, "wb") as output:
        if not response.url.startswith("https://"):
            raise ValueError("Refusing a non-HTTPS download")
        total = 0
        while True:
            chunk = response.read(65536)
            if not chunk:
                break
            total += len(chunk)
            if total > limit:
                raise ValueError("Download exceeded size limit")
            output.write(chunk)


def extract_bundle(archive_path, destination, sha):
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("Invalid GitHub commit")
    prefix = f"OpsVault-{sha}/xray/marzban-suricata-ips/"
    with tarfile.open(archive_path, "r:gz") as archive:
        selected = {}
        expanded = 0
        # Iterate with a member bound instead of materializing an unbounded archive index.
        for index, member in enumerate(archive):
            if index > 100000:
                raise ValueError("Too many archive members")
            expanded += member.size
            if expanded > 256 * 1024 * 1024:
                raise ValueError("Expanded archive too large")
            if not member.name.startswith(prefix):
                continue
            name = member.name[len(prefix):]
            if name not in FILES:
                continue
            if name in selected or not member.isfile() or member.size > 2 * 1024 * 1024:
                raise ValueError(f"Invalid bundle member: {name}")
            selected[name] = member
        if set(selected) != set(FILES):
            raise ValueError("Incomplete project bundle")
        if sum(member.size for member in selected.values()) > 8 * 1024 * 1024:
            raise ValueError("Project bundle too large")
        for name, member in selected.items():
            with archive.extractfile(member) as source, open(Path(destination) / name, "xb") as target:
                target.write(source.read(member.size))
        return (Path(destination) / "VERSION").read_text(encoding="ascii").strip()


def main():
    parser = argparse.ArgumentParser(description="Update Marzban IPS itself from GitHub")
    parser.add_argument("--force", action="store_true", help="reinstall the published version, including an older version")
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise ValueError("Run with sudo")
    current_path = Path("/etc/marzban-ips/version")
    current = current_path.read_text(encoding="ascii").strip() if current_path.exists() else "2.0.0"
    with tempfile.TemporaryDirectory(prefix="marzban-ips-upgrade-") as temporary:
        stage = Path(temporary)
        download(f"https://api.github.com/repos/{REPOSITORY}/commits/main", stage / "commit.json", 1024 * 1024)
        sha = json.loads((stage / "commit.json").read_text(encoding="utf-8"))["sha"]
        if not re.fullmatch(r"[0-9a-f]{40}", sha):
            raise ValueError("Invalid GitHub commit")
        download(f"https://codeload.github.com/{REPOSITORY}/tar.gz/{sha}", stage / "bundle.tgz", 64 * 1024 * 1024)
        new_version = extract_bundle(stage / "bundle.tgz", stage, sha)
        version(new_version)
        version(current)
        print(f"Installed: {current} | GitHub: {new_version}", flush=True)
        if version(new_version) <= version(current) and not args.force:
            print("Already up to date. Use upgrade --force to reinstall the published version.")
            return
        process = subprocess.Popen(["bash", str(stage / "install.sh"), "--upgrade"], start_new_session=True)
        try:
            result = process.wait(timeout=600)
        except (subprocess.TimeoutExpired, KeyboardInterrupt) as interruption:
            # Give the upgrade's EXIT trap time to restore the previous package.
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=60)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            reason = "timed out" if isinstance(interruption, subprocess.TimeoutExpired) else "was cancelled"
            raise ValueError(f"Upgrade {reason}; inspect the saved backup and service state")
        if result:
            raise ValueError(f"Upgrade exited with status {result}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, tarfile.TarError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        raise SystemExit(f"ERROR: project upgrade failed: {error}")
