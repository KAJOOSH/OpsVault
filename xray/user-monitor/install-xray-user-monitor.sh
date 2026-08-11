#!/usr/bin/env bash
set -Eeuo pipefail

# Xray / Marzban Node historical user load monitor
# Target: Debian/Ubuntu Linux with systemd
# Installs a lightweight background monitor backed by SQLite.

APP_DIR="/opt/xray-user-monitor"
DATA_DIR="/var/lib/xray-user-monitor"
CONF_FILE="/etc/xray-user-monitor.conf"
SERVICE_FILE="/etc/systemd/system/xray-user-monitor.service"
GRPCURL_VERSION="1.9.3"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "ERROR: Run this installer as root." >&2
  exit 1
fi

install_pkgs_if_missing() {
  local missing=()
  command -v python3 >/dev/null 2>&1 || missing+=(python3)
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v ss >/dev/null 2>&1 || missing+=(iproute2)
  [[ -f /etc/ssl/certs/ca-certificates.crt ]] || missing+=(ca-certificates)

  if ((${#missing[@]})); then
    echo "Installing required packages: ${missing[*]}"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
  fi
}

install_grpcurl() {
  if command -v grpcurl >/dev/null 2>&1; then
    echo "grpcurl already installed: $(grpcurl --version 2>/dev/null || true)"
    return
  fi

  local arch deb tmp checksum_file
  case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
    amd64|x86_64) arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    *)
      echo "ERROR: Unsupported architecture for automatic grpcurl install." >&2
      echo "Install grpcurl manually, then run this installer again." >&2
      exit 1
      ;;
  esac

  deb="grpcurl_${GRPCURL_VERSION}_linux_${arch}.deb"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  echo "Installing grpcurl v${GRPCURL_VERSION} (${arch})..."
  curl -fL --retry 3 --connect-timeout 10 \
    "https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/${deb}" \
    -o "$tmp/$deb"
  curl -fL --retry 3 --connect-timeout 10 \
    "https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/grpcurl_${GRPCURL_VERSION}_checksums.txt" \
    -o "$tmp/checksums.txt"

  (
    cd "$tmp"
    grep "  ${deb}$" checksums.txt | sha256sum -c -
  )

  dpkg -i "$tmp/$deb"
  rm -rf "$tmp"
  trap - RETURN
}

install_pkgs_if_missing
install_grpcurl

mkdir -p "$APP_DIR" "$DATA_DIR"
chmod 0755 "$APP_DIR"
chmod 0700 "$DATA_DIR"

cat > "$APP_DIR/command.proto" <<'PROTO'
syntax = "proto3";
package xray.app.stats.command;

message Stat {
  string name = 1;
  int64 value = 2;
}

message QueryStatsRequest {
  string pattern = 1;
  bool reset = 2;
}

message QueryStatsResponse {
  repeated Stat stat = 1;
}

message OnlineIPEntry {
  string ip = 1;
  int64 last_seen = 2;
}

message TrafficUserStat {
  int64 uplink = 1;
  int64 downlink = 2;
}

message UserStat {
  string email = 1;
  repeated OnlineIPEntry ips = 2;
  TrafficUserStat traffic = 3;
}

message GetUsersStatsRequest {
  bool include_traffic = 1;
  bool reset = 2;
}

message GetUsersStatsResponse {
  repeated UserStat users = 1;
}

service StatsService {
  rpc QueryStats(QueryStatsRequest) returns (QueryStatsResponse) {}
  rpc GetUsersStats(GetUsersStatsRequest) returns (GetUsersStatsResponse) {}
}
PROTO

cat > "$APP_DIR/monitor.py" <<'PY'
#!/usr/bin/env python3
import ipaddress
import json
import math
import os
import re
import signal
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

APP_DIR = Path("/opt/xray-user-monitor")
DATA_DIR = Path("/var/lib/xray-user-monitor")
DB_PATH = DATA_DIR / "history.db"
EVENT_LOG = DATA_DIR / "events.log"
PROTO = APP_DIR / "command.proto"
GRPCURL = "/usr/bin/grpcurl" if Path("/usr/bin/grpcurl").exists() else "grpcurl"

API_HOST = os.getenv("XRAY_API_HOST", "127.0.0.1")
API_PORT = int(os.getenv("XRAY_API_PORT", "62051"))
SAMPLE_INTERVAL = max(5, int(os.getenv("SAMPLE_INTERVAL", "15")))
CPU_EVENT_THRESHOLD = max(1.0, float(os.getenv("CPU_EVENT_THRESHOLD", "100")))
CPU_CLEAR_THRESHOLD = max(0.0, float(os.getenv("CPU_CLEAR_THRESHOLD", "70")))
EVENT_CLEAR_SAMPLES = max(1, int(os.getenv("EVENT_CLEAR_SAMPLES", "3")))
TOP_USERS = max(3, int(os.getenv("TOP_USERS", "10")))
RETENTION_DAYS = max(1, int(os.getenv("RETENTION_DAYS", "30")))
DEEP_SCAN = os.getenv("DEEP_SCAN_ON_HIGH_CPU", "1").strip().lower() not in {"0", "false", "no"}
RPC_TIMEOUT = max(1, int(os.getenv("RPC_TIMEOUT", "4")))

CLK_TCK = os.sysconf(os.sysconf_names["SC_CLK_TCK"])
PAGE_SIZE = os.sysconf("SC_PAGE_SIZE")
STOP = False


def log(msg):
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}", flush=True)


def breadcrumb(msg):
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    with open(EVENT_LOG, "a", encoding="utf-8") as f:
        f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
        f.flush()
        os.fsync(f.fileno())


def handle_signal(signum, frame):
    global STOP
    STOP = True


signal.signal(signal.SIGTERM, handle_signal)
signal.signal(signal.SIGINT, handle_signal)


def db_open():
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH, timeout=5)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute("PRAGMA temp_store=MEMORY")
    conn.execute("PRAGMA busy_timeout=5000")
    conn.execute("PRAGMA auto_vacuum=INCREMENTAL")
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS samples (
            ts INTEGER PRIMARY KEY,
            pid INTEGER,
            cpu_pct REAL NOT NULL DEFAULT 0,
            rss_mb REAL NOT NULL DEFAULT 0,
            threads INTEGER NOT NULL DEFAULT 0,
            total_mbps REAL NOT NULL DEFAULT 0,
            up_mbps REAL NOT NULL DEFAULT 0,
            down_mbps REAL NOT NULL DEFAULT 0,
            top_user TEXT,
            top_user_mbps REAL NOT NULL DEFAULT 0,
            active_users INTEGER NOT NULL DEFAULT 0,
            api_ok INTEGER NOT NULL DEFAULT 0,
            api_mode TEXT,
            event_id INTEGER
        );

        CREATE TABLE IF NOT EXISTS user_samples (
            ts INTEGER NOT NULL,
            username TEXT NOT NULL,
            email TEXT NOT NULL,
            up_mbps REAL NOT NULL DEFAULT 0,
            down_mbps REAL NOT NULL DEFAULT 0,
            total_mbps REAL NOT NULL DEFAULT 0,
            online_ips INTEGER NOT NULL DEFAULT 0,
            tcp_conn INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (ts, email)
        ) WITHOUT ROWID;

        CREATE INDEX IF NOT EXISTS idx_user_samples_username_ts
            ON user_samples(username, ts);

        CREATE INDEX IF NOT EXISTS idx_user_samples_ts
            ON user_samples(ts);

        CREATE TABLE IF NOT EXISTS events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            start_ts INTEGER NOT NULL,
            end_ts INTEGER,
            peak_ts INTEGER NOT NULL,
            peak_cpu_pct REAL NOT NULL,
            peak_total_mbps REAL NOT NULL DEFAULT 0,
            peak_user TEXT,
            peak_user_mbps REAL NOT NULL DEFAULT 0,
            peak_user_tcp_conn INTEGER NOT NULL DEFAULT 0,
            peak_user_online_ips INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL DEFAULT 'active'
        );

        CREATE INDEX IF NOT EXISTS idx_events_start_ts ON events(start_ts);
        """
    )
    conn.commit()
    return conn


def clean_stale_event(conn):
    row = conn.execute(
        "SELECT id, start_ts FROM events WHERE status='active' ORDER BY id DESC LIMIT 1"
    ).fetchone()
    if row:
        last_ts = conn.execute("SELECT MAX(ts) FROM samples").fetchone()[0]
        conn.execute(
            "UPDATE events SET end_ts=?, status='interrupted' WHERE id=?",
            (last_ts or row[1], row[0]),
        )
        conn.commit()


def find_xray_pid():
    candidates = []
    proc = Path("/proc")
    try:
        entries = proc.iterdir()
    except OSError:
        return None
    for entry in entries:
        if not entry.name.isdigit():
            continue
        try:
            comm = (entry / "comm").read_text(errors="ignore").strip()
            if comm != "xray":
                continue
            stat = read_proc_stat(int(entry.name))
            if stat:
                candidates.append((stat["starttime"], int(entry.name)))
        except (OSError, ValueError):
            continue
    if not candidates:
        return None
    candidates.sort(reverse=True)
    return candidates[0][1]


def read_proc_stat(pid):
    try:
        raw = Path(f"/proc/{pid}/stat").read_text()
        rparen = raw.rfind(")")
        if rparen < 0:
            return None
        fields = raw[rparen + 2 :].split()
        # fields[0] == original field 3 (state)
        utime = int(fields[11])
        stime = int(fields[12])
        threads = int(fields[17])
        starttime = int(fields[19])

        statm = Path(f"/proc/{pid}/statm").read_text().split()
        rss_pages = int(statm[1]) if len(statm) > 1 else 0
        rss_mb = rss_pages * PAGE_SIZE / (1024 * 1024)
        return {
            "ticks": utime + stime,
            "threads": threads,
            "starttime": starttime,
            "rss_mb": rss_mb,
        }
    except (OSError, ValueError, IndexError):
        return None


def normalize_ip(value):
    if not value:
        return None
    value = value.strip().strip("[]")
    try:
        ip = ipaddress.ip_address(value)
        if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped:
            return str(ip.ipv4_mapped)
        return str(ip)
    except ValueError:
        return value


def username_from_email(email):
    # Marzban normally uses: <numeric-user-id>.<username>
    m = re.match(r"^\d+\.(.+)$", email or "")
    return m.group(1) if m else (email or "unknown")


def grpc_call(method, payload):
    cmd = [
        GRPCURL,
        "-insecure",
        "-max-time",
        str(RPC_TIMEOUT),
        "-import-path",
        str(APP_DIR),
        "-proto",
        PROTO.name,
        "-d",
        json.dumps(payload, separators=(",", ":")),
        f"{API_HOST}:{API_PORT}",
        f"xray.app.stats.command.StatsService/{method}",
    ]
    cp = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=RPC_TIMEOUT + 2,
    )
    if cp.returncode != 0:
        raise RuntimeError(cp.stderr.strip() or f"grpcurl exit={cp.returncode}")
    return json.loads(cp.stdout or "{}")


def query_traffic_stats():
    # QueryStats is the authoritative cumulative per-user traffic source and
    # includes counters even when a user is no longer in the online-IP map.
    data = grpc_call("QueryStats", {"pattern": "user>>>", "reset": False})
    result = {}
    for item in data.get("stat", []) or []:
        name = item.get("name") or ""
        m = re.match(r"^user>>>(.*?)>>>traffic>>>(uplink|downlink)$", name)
        if not m:
            continue
        email, direction = m.groups()
        row = result.setdefault(email, {"up": 0, "down": 0, "ips": set()})
        row["up" if direction == "uplink" else "down"] = int(item.get("value") or 0)
    return result


def query_online_ips():
    # Newer Xray builds expose GetUsersStats. It is based on online maps, so we
    # use it only as an incident-time enrichment source, never as traffic truth.
    data = grpc_call("GetUsersStats", {"includeTraffic": False, "reset": False})
    result = {}
    for u in data.get("users", []) or []:
        email = u.get("email") or ""
        if not email:
            continue
        ips = set()
        for item in (u.get("ips") or []):
            ip = normalize_ip(item.get("ip") if isinstance(item, dict) else None)
            if ip:
                ips.add(ip)
        if ips:
            result[email] = ips
    return result


def peer_ip_from_ss_token(token):
    token = token.strip()
    if token.startswith("[") and "]" in token:
        return normalize_ip(token[1 : token.rfind("]")])
    if ":" in token:
        host = token.rsplit(":", 1)[0]
        return normalize_ip(host)
    return normalize_ip(token)


def tcp_connections_by_user(pid, stats):
    if not stats or not any(v.get("ips") for v in stats.values()):
        return {}

    ip_owners = {}
    for email, row in stats.items():
        for ip in row.get("ips", set()):
            ip_owners.setdefault(ip, set()).add(email)

    try:
        cp = subprocess.run(
            ["ss", "-Htnp", "state", "established"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=4,
        )
    except Exception:
        return {}

    peer_counts = {}
    pid_marker = f"pid={pid},"
    for line in cp.stdout.splitlines():
        if pid_marker not in line:
            continue
        parts = line.split()
        # With `ss -Htnp state established`, the last endpoint before process
        # metadata is the peer endpoint. Locate process metadata, then step back.
        proc_idx = None
        for i, token in enumerate(parts):
            if "users:((" in token or token.startswith("users:("):
                proc_idx = i
                break
        if proc_idx is None or proc_idx < 1:
            # Fallback for common ss column layout.
            if len(parts) >= 5:
                peer_token = parts[4]
            else:
                continue
        else:
            peer_token = parts[proc_idx - 1]
        ip = peer_ip_from_ss_token(peer_token)
        if ip:
            peer_counts[ip] = peer_counts.get(ip, 0) + 1

    by_user = {}
    for ip, count in peer_counts.items():
        owners = ip_owners.get(ip, set())
        # Only attribute when the IP maps uniquely to one Xray user.
        if len(owners) == 1:
            email = next(iter(owners))
            by_user[email] = by_user.get(email, 0) + count
    return by_user


def bytes_delta(current, previous):
    if previous is None or current < previous:
        return 0
    return current - previous


def cleanup(conn, now_ts):
    cutoff = now_ts - RETENTION_DAYS * 86400
    with conn:
        conn.execute("DELETE FROM user_samples WHERE ts < ?", (cutoff,))
        conn.execute("DELETE FROM samples WHERE ts < ?", (cutoff,))
        conn.execute(
            "DELETE FROM events WHERE COALESCE(end_ts, start_ts) < ? AND status != 'active'",
            (cutoff,),
        )
    try:
        conn.execute("PRAGMA wal_checkpoint(PASSIVE)")
        conn.execute("PRAGMA incremental_vacuum(500)")
    except sqlite3.DatabaseError:
        pass


def main():
    conn = db_open()
    clean_stale_event(conn)

    last_pid = None
    last_proc_ticks = None
    last_proc_mono = None
    previous_stats = None
    last_stats_mono = None
    api_mode = None
    active_event = None
    clear_count = 0
    next_cleanup = time.time() + 3600
    last_error_log = 0.0

    log(
        f"started: api={API_HOST}:{API_PORT}, interval={SAMPLE_INTERVAL}s, "
        f"cpu_event={CPU_EVENT_THRESHOLD:.0f}%, retention={RETENTION_DAYS}d, top={TOP_USERS}"
    )

    while not STOP:
        loop_started = time.monotonic()
        now_ts = int(time.time())
        pid = find_xray_pid()

        if pid is None:
            if time.time() - last_error_log > 60:
                log("Xray process not found; waiting...")
                last_error_log = time.time()
            last_pid = None
            last_proc_ticks = None
            last_proc_mono = None
            previous_stats = None
            last_stats_mono = None
            time.sleep(min(SAMPLE_INTERVAL, 5))
            continue

        proc = read_proc_stat(pid)
        now_mono = time.monotonic()
        cpu_pct = 0.0
        rss_mb = 0.0
        threads = 0

        if proc:
            rss_mb = proc["rss_mb"]
            threads = proc["threads"]
            if pid == last_pid and last_proc_ticks is not None and last_proc_mono is not None:
                elapsed = now_mono - last_proc_mono
                if elapsed > 0:
                    cpu_pct = max(
                        0.0,
                        (proc["ticks"] - last_proc_ticks) / CLK_TCK / elapsed * 100.0,
                    )
            last_proc_ticks = proc["ticks"]
            last_proc_mono = now_mono

        if pid != last_pid:
            previous_stats = None
            last_stats_mono = None
            if last_pid is not None:
                log(f"Xray PID changed: {last_pid} -> {pid}; traffic baseline reset")
            last_pid = pid

        api_ok = 0
        stats = {}
        mode = "QueryStats"
        try:
            stats = query_traffic_stats()
            api_mode = "QueryStats"
            api_ok = 1
        except Exception as exc:
            if time.time() - last_error_log > 60:
                log(f"Stats API error: {exc}")
                last_error_log = time.time()

        stats_now_mono = time.monotonic()
        if last_stats_mono is None:
            stats_elapsed = float(SAMPLE_INTERVAL)
        else:
            stats_elapsed = max(0.001, stats_now_mono - last_stats_mono)

        user_rows = []
        total_up_bps = 0.0
        total_down_bps = 0.0
        active_users = 0

        if api_ok and previous_stats is not None:
            for email, cur in stats.items():
                prev = previous_stats.get(email)
                if prev is None:
                    continue
                up_bytes = bytes_delta(cur.get("up", 0), prev.get("up", 0))
                down_bytes = bytes_delta(cur.get("down", 0), prev.get("down", 0))
                up_bps = up_bytes * 8.0 / stats_elapsed
                down_bps = down_bytes * 8.0 / stats_elapsed
                total_bps = up_bps + down_bps
                if total_bps > 0:
                    active_users += 1
                total_up_bps += up_bps
                total_down_bps += down_bps
                user_rows.append(
                    {
                        "email": email,
                        "username": username_from_email(email),
                        "up_mbps": up_bps / 1_000_000.0,
                        "down_mbps": down_bps / 1_000_000.0,
                        "total_mbps": total_bps / 1_000_000.0,
                        "online_ips": len(cur.get("ips") or set()),
                        "tcp_conn": 0,
                    }
                )

        if api_ok:
            previous_stats = stats
            last_stats_mono = stats_now_mono

        total_mbps = (total_up_bps + total_down_bps) / 1_000_000.0
        up_mbps = total_up_bps / 1_000_000.0
        down_mbps = total_down_bps / 1_000_000.0

        high_cpu = cpu_pct >= CPU_EVENT_THRESHOLD
        conn_by_email = {}
        if high_cpu and DEEP_SCAN and api_ok:
            try:
                online = query_online_ips()
                for email, ips in online.items():
                    if email in stats:
                        stats[email]["ips"] = ips
                    else:
                        stats[email] = {"up": 0, "down": 0, "ips": ips}
                mode = "QueryStats+OnlineIPs"
                conn_by_email = tcp_connections_by_user(pid, stats)
            except Exception:
                # Older Xray versions or configs without online maps simply
                # continue with traffic-only attribution.
                conn_by_email = {}

            by_email = {r["email"]: r for r in user_rows}
            for email, cur in stats.items():
                if not cur.get("ips") and email not in conn_by_email:
                    continue
                row = by_email.get(email)
                if row is None:
                    row = {
                        "email": email,
                        "username": username_from_email(email),
                        "up_mbps": 0.0,
                        "down_mbps": 0.0,
                        "total_mbps": 0.0,
                        "online_ips": len(cur.get("ips") or set()),
                        "tcp_conn": 0,
                    }
                    user_rows.append(row)
                    by_email[email] = row
                else:
                    row["online_ips"] = len(cur.get("ips") or set())
                row["tcp_conn"] = conn_by_email.get(email, 0)

        traffic_sorted = sorted(user_rows, key=lambda r: r["total_mbps"], reverse=True)
        conn_sorted = sorted(user_rows, key=lambda r: r["tcp_conn"], reverse=True)
        top_row = traffic_sorted[0] if traffic_sorted else None

        selected = {}
        for row in traffic_sorted[:TOP_USERS]:
            if row["total_mbps"] > 0 or high_cpu:
                selected[row["email"]] = row
        if high_cpu:
            for row in conn_sorted[:TOP_USERS]:
                if row["tcp_conn"] > 0:
                    selected[row["email"]] = row

        # Event state machine with hysteresis.
        new_event_started = False
        event_ended = False
        if active_event is None and high_cpu:
            cur = conn.execute(
                """
                INSERT INTO events(
                    start_ts, peak_ts, peak_cpu_pct, peak_total_mbps,
                    peak_user, peak_user_mbps, peak_user_tcp_conn,
                    peak_user_online_ips, status
                ) VALUES(?,?,?,?,?,?,?,?, 'active')
                """,
                (
                    now_ts,
                    now_ts,
                    cpu_pct,
                    total_mbps,
                    top_row["username"] if top_row else None,
                    top_row["total_mbps"] if top_row else 0.0,
                    top_row["tcp_conn"] if top_row else 0,
                    top_row["online_ips"] if top_row else 0,
                ),
            )
            active_event = cur.lastrowid
            clear_count = 0
            new_event_started = True
        elif active_event is not None:
            if high_cpu:
                clear_count = 0
            elif cpu_pct < CPU_CLEAR_THRESHOLD:
                clear_count += 1
            else:
                clear_count = 0

            event_peak = conn.execute(
                "SELECT peak_cpu_pct FROM events WHERE id=?", (active_event,)
            ).fetchone()
            if event_peak and cpu_pct > float(event_peak[0]):
                conn.execute(
                    """
                    UPDATE events
                    SET peak_ts=?, peak_cpu_pct=?, peak_total_mbps=?,
                        peak_user=?, peak_user_mbps=?, peak_user_tcp_conn=?,
                        peak_user_online_ips=?
                    WHERE id=?
                    """,
                    (
                        now_ts,
                        cpu_pct,
                        total_mbps,
                        top_row["username"] if top_row else None,
                        top_row["total_mbps"] if top_row else 0.0,
                        top_row["tcp_conn"] if top_row else 0,
                        top_row["online_ips"] if top_row else 0,
                        active_event,
                    ),
                )

            if clear_count >= EVENT_CLEAR_SAMPLES:
                conn.execute(
                    "UPDATE events SET end_ts=?, status='ended' WHERE id=?",
                    (now_ts, active_event),
                )
                event_ended = True

        sample_event_id = active_event

        with conn:
            conn.execute(
                """
                INSERT OR REPLACE INTO samples(
                    ts,pid,cpu_pct,rss_mb,threads,total_mbps,up_mbps,down_mbps,
                    top_user,top_user_mbps,active_users,api_ok,api_mode,event_id
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """,
                (
                    now_ts,
                    pid,
                    cpu_pct,
                    rss_mb,
                    threads,
                    total_mbps,
                    up_mbps,
                    down_mbps,
                    top_row["username"] if top_row else None,
                    top_row["total_mbps"] if top_row else 0.0,
                    active_users,
                    api_ok,
                    mode,
                    sample_event_id,
                ),
            )
            for row in selected.values():
                conn.execute(
                    """
                    INSERT OR REPLACE INTO user_samples(
                        ts,username,email,up_mbps,down_mbps,total_mbps,online_ips,tcp_conn
                    ) VALUES(?,?,?,?,?,?,?,?)
                    """,
                    (
                        now_ts,
                        row["username"],
                        row["email"],
                        row["up_mbps"],
                        row["down_mbps"],
                        row["total_mbps"],
                        row["online_ips"],
                        row["tcp_conn"],
                    ),
                )

        if new_event_started:
            breadcrumb(
                f"EVENT_START id={active_event} cpu={cpu_pct:.1f}% "
                f"top_user={(top_row['username'] if top_row else '-')} "
                f"top_mbps={(top_row['total_mbps'] if top_row else 0):.2f}"
            )
            log(
                f"HIGH CPU event #{active_event} started: cpu={cpu_pct:.1f}% "
                f"top={(top_row['username'] if top_row else '-')} "
                f"{(top_row['total_mbps'] if top_row else 0):.2f} Mbps"
            )

        if event_ended:
            breadcrumb(f"EVENT_END id={active_event} cpu={cpu_pct:.1f}%")
            log(f"HIGH CPU event #{active_event} ended")
            active_event = None
            clear_count = 0

        if time.time() >= next_cleanup:
            cleanup(conn, now_ts)
            next_cleanup = time.time() + 86400

        elapsed_loop = time.monotonic() - loop_started
        sleep_for = max(0.2, SAMPLE_INTERVAL - elapsed_loop)
        end = time.monotonic() + sleep_for
        while not STOP:
            remain = end - time.monotonic()
            if remain <= 0:
                break
            time.sleep(min(1.0, remain))

    if active_event is not None:
        now_ts = int(time.time())
        with conn:
            conn.execute(
                "UPDATE events SET end_ts=?, status='service-stopped' WHERE id=?",
                (now_ts, active_event),
            )
        breadcrumb(f"EVENT_STOP id={active_event} reason=service-stopped")
    conn.close()
    log("stopped")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        log(f"FATAL: {exc}")
        raise
PY

cat > "$APP_DIR/report.py" <<'PY'
#!/usr/bin/env python3
import os
import sqlite3
import sys
from datetime import datetime
from pathlib import Path

DB = Path("/var/lib/xray-user-monitor/history.db")


def fmt_ts(ts):
    if not ts:
        return "-"
    return datetime.fromtimestamp(int(ts)).strftime("%Y-%m-%d %H:%M:%S")


def db():
    if not DB.exists():
        print("No history database yet.")
        sys.exit(1)
    return sqlite3.connect(f"file:{DB}?mode=ro", uri=True)


def print_table(headers, rows):
    rows = [["" if v is None else str(v) for v in r] for r in rows]
    widths = [len(h) for h in headers]
    for r in rows:
        for i, v in enumerate(r):
            widths[i] = max(widths[i], len(v))
    fmt = "  ".join("{:<" + str(w) + "}" for w in widths)
    print(fmt.format(*headers))
    print(fmt.format(*["-" * w for w in widths]))
    for r in rows:
        print(fmt.format(*r))


def cmd_status(conn):
    s = conn.execute(
        """
        SELECT ts,pid,cpu_pct,rss_mb,threads,total_mbps,up_mbps,down_mbps,
               top_user,top_user_mbps,active_users,api_ok,api_mode,event_id
        FROM samples ORDER BY ts DESC LIMIT 1
        """
    ).fetchone()
    if not s:
        print("No samples yet.")
        return
    print(f"Time        : {fmt_ts(s[0])}")
    print(f"Xray PID    : {s[1]}")
    print(f"Xray CPU    : {s[2]:.1f}%  (100% = one fully used CPU core)")
    print(f"Xray RAM    : {s[3]:.1f} MiB")
    print(f"Threads     : {s[4]}")
    print(f"User traffic: {s[5]:.2f} Mbps  UP={s[6]:.2f}  DOWN={s[7]:.2f}")
    print(f"Top user    : {s[8] or '-'}  {s[9]:.2f} Mbps")
    print(f"Active users: {s[10]}")
    print(f"Stats API   : {'OK' if s[11] else 'ERROR'} ({s[12] or '-'})")
    print(f"Event       : {s[13] or '-'}")
    users = conn.execute(
        """
        SELECT username,total_mbps,up_mbps,down_mbps,online_ips,tcp_conn
        FROM user_samples WHERE ts=?
        ORDER BY total_mbps DESC, tcp_conn DESC LIMIT 15
        """,
        (s[0],),
    ).fetchall()
    if users:
        print("\nTop users in this sample:")
        print_table(
            ["USER", "Mbps", "UP", "DOWN", "IPs", "TCP"],
            [
                [u[0], f"{u[1]:.2f}", f"{u[2]:.2f}", f"{u[3]:.2f}", u[4], u[5]]
                for u in users
            ],
        )


def cmd_events(conn, hours):
    cutoff = int(datetime.now().timestamp()) - int(hours * 3600)
    rows = conn.execute(
        """
        SELECT id,start_ts,end_ts,peak_ts,peak_cpu_pct,peak_total_mbps,
               peak_user,peak_user_mbps,peak_user_tcp_conn,
               peak_user_online_ips,status
        FROM events WHERE start_ts>=? ORDER BY start_ts DESC LIMIT 100
        """,
        (cutoff,),
    ).fetchall()
    print_table(
        ["ID", "START", "END", "PEAK CPU", "PEAK USER", "USER Mbps", "TCP", "IPs", "STATUS"],
        [
            [
                r[0], fmt_ts(r[1]), fmt_ts(r[2]), f"{r[4]:.1f}%",
                r[6] or "-", f"{r[7]:.2f}", r[8], r[9], r[10]
            ]
            for r in rows
        ],
    )


def cmd_top(conn, hours):
    cutoff = int(datetime.now().timestamp()) - int(hours * 3600)
    rows = conn.execute(
        """
        SELECT username,
               MAX(total_mbps) AS peak_mbps,
               AVG(total_mbps) AS avg_when_recorded,
               MAX(tcp_conn) AS max_tcp,
               MAX(online_ips) AS max_ips,
               COUNT(*) AS appearances
        FROM user_samples
        WHERE ts>=?
        GROUP BY username
        ORDER BY peak_mbps DESC, max_tcp DESC
        LIMIT 50
        """,
        (cutoff,),
    ).fetchall()
    print_table(
        ["USER", "PEAK Mbps", "AVG* Mbps", "MAX TCP", "MAX IPs", "TOP SAMPLES"],
        [
            [r[0], f"{r[1]:.2f}", f"{r[2]:.2f}", r[3], r[4], r[5]]
            for r in rows
        ],
    )
    print("\n* AVG is only across samples where the user was retained in the Top-N history.")


def cmd_user(conn, username, hours):
    cutoff = int(datetime.now().timestamp()) - int(hours * 3600)
    summary = conn.execute(
        """
        SELECT MAX(total_mbps),AVG(total_mbps),MAX(tcp_conn),MAX(online_ips),COUNT(*)
        FROM user_samples WHERE username=? AND ts>=?
        """,
        (username, cutoff),
    ).fetchone()
    if not summary or summary[4] == 0:
        print("No retained samples for this user in the requested window.")
        return
    print(f"User        : {username}")
    print(f"Peak traffic: {summary[0]:.2f} Mbps")
    print(f"Max TCP     : {summary[2]}")
    print(f"Max IPs     : {summary[3]}")
    print(f"Samples     : {summary[4]}")
    rows = conn.execute(
        """
        SELECT ts,total_mbps,up_mbps,down_mbps,online_ips,tcp_conn
        FROM user_samples WHERE username=? AND ts>=?
        ORDER BY ts DESC LIMIT 50
        """,
        (username, cutoff),
    ).fetchall()
    print("\nLatest retained samples:")
    print_table(
        ["TIME", "Mbps", "UP", "DOWN", "IPs", "TCP"],
        [
            [fmt_ts(r[0]), f"{r[1]:.2f}", f"{r[2]:.2f}", f"{r[3]:.2f}", r[4], r[5]]
            for r in rows
        ],
    )


def cmd_show(conn, event_id):
    e = conn.execute(
        """
        SELECT id,start_ts,end_ts,peak_ts,peak_cpu_pct,peak_total_mbps,
               peak_user,peak_user_mbps,peak_user_tcp_conn,
               peak_user_online_ips,status
        FROM events WHERE id=?
        """,
        (event_id,),
    ).fetchone()
    if not e:
        print("Event not found.")
        return
    print(f"Event       : #{e[0]} ({e[10]})")
    print(f"Start       : {fmt_ts(e[1])}")
    print(f"End         : {fmt_ts(e[2])}")
    print(f"Peak time   : {fmt_ts(e[3])}")
    print(f"Peak CPU    : {e[4]:.1f}%")
    print(f"Total Mbps  : {e[5]:.2f}")
    print(f"Peak user   : {e[6] or '-'}")
    print(f"User Mbps   : {e[7]:.2f}")
    print(f"User TCP    : {e[8]}")
    print(f"User IPs    : {e[9]}")

    rows = conn.execute(
        """
        SELECT ts,cpu_pct,rss_mb,total_mbps,top_user,top_user_mbps,active_users,api_mode
        FROM samples
        WHERE ts BETWEEN ? AND ?
        ORDER BY ABS(ts-?) ASC LIMIT 15
        """,
        (e[3] - 120, e[3] + 120, e[3]),
    ).fetchall()
    rows.sort(key=lambda r: r[0])
    if rows:
        print("\nSamples around peak:")
        print_table(
            ["TIME", "CPU", "RAM", "TOTAL Mbps", "TOP USER", "USER Mbps", "ACTIVE", "API"],
            [
                [fmt_ts(r[0]), f"{r[1]:.1f}%", f"{r[2]:.0f}M", f"{r[3]:.2f}", r[4] or "-", f"{r[5]:.2f}", r[6], r[7] or "-"]
                for r in rows
            ],
        )

    users = conn.execute(
        """
        SELECT username,total_mbps,up_mbps,down_mbps,online_ips,tcp_conn
        FROM user_samples WHERE ts=?
        ORDER BY tcp_conn DESC,total_mbps DESC LIMIT 30
        """,
        (e[3],),
    ).fetchall()
    if users:
        print("\nUsers at the CPU peak:")
        print_table(
            ["USER", "Mbps", "UP", "DOWN", "IPs", "TCP"],
            [[r[0], f"{r[1]:.2f}", f"{r[2]:.2f}", f"{r[3]:.2f}", r[4], r[5]] for r in users],
        )


def cmd_size(conn):
    conn.close()
    files = [DB, Path(str(DB) + "-wal"), Path(str(DB) + "-shm")]
    total = 0
    for p in files:
        if p.exists():
            size = p.stat().st_size
            total += size
            print(f"{p}: {size / (1024*1024):.2f} MiB")
    print(f"Total: {total / (1024*1024):.2f} MiB")


def usage():
    print("""Usage:
  xraymon status
  xraymon events [hours]          # default: 168 (7 days)
  xraymon show <event-id>
  xraymon top [hours]             # default: 24
  xraymon user <username> [hours] # default: 24
  xraymon size

Examples:
  xraymon status
  xraymon events 168
  xraymon show 3
  xraymon top 24
  xraymon user ali 48
  watch -n 5 xraymon status
""")


def main():
    if len(sys.argv) < 2:
        usage()
        return 1
    command = sys.argv[1].lower()
    conn = db()
    if command == "status":
        cmd_status(conn)
    elif command == "events":
        cmd_events(conn, float(sys.argv[2]) if len(sys.argv) > 2 else 168)
    elif command == "show" and len(sys.argv) > 2:
        cmd_show(conn, int(sys.argv[2]))
    elif command == "top":
        cmd_top(conn, float(sys.argv[2]) if len(sys.argv) > 2 else 24)
    elif command == "user" and len(sys.argv) > 2:
        cmd_user(conn, sys.argv[2], float(sys.argv[3]) if len(sys.argv) > 3 else 24)
    elif command == "size":
        cmd_size(conn)
        return 0
    else:
        usage()
        return 1
    conn.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY

chmod 0755 "$APP_DIR/monitor.py" "$APP_DIR/report.py"
ln -sf "$APP_DIR/report.py" /usr/local/bin/xraymon

if [[ ! -f "$CONF_FILE" ]]; then
cat > "$CONF_FILE" <<'CONF'
# Marzban Node Xray API
XRAY_API_HOST=127.0.0.1
XRAY_API_PORT=62051

# Poll interval. 15 seconds is a good balance between visibility and overhead.
SAMPLE_INTERVAL=15

# Xray CPU is process CPU: 100% means one CPU core fully utilized.
CPU_EVENT_THRESHOLD=100
CPU_CLEAR_THRESHOLD=70
EVENT_CLEAR_SAMPLES=3

# Persist only the busiest users per sample to keep SQLite small.
TOP_USERS=10

# Automatic history retention.
RETENTION_DAYS=30

# When CPU is high and Xray supports GetUsersStats, correlate online client IPs
# with Xray-owned established TCP sockets. This runs ONLY during high CPU.
DEEP_SCAN_ON_HIGH_CPU=1

# gRPC query timeout in seconds.
RPC_TIMEOUT=4
CONF
fi
chmod 0644 "$CONF_FILE"

cat > "$SERVICE_FILE" <<'SERVICE'
[Unit]
Description=Lightweight Xray per-user historical load monitor
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-/etc/xray-user-monitor.conf
ExecStart=/usr/bin/python3 /opt/xray-user-monitor/monitor.py
Restart=always
RestartSec=5
Nice=15
IOSchedulingClass=idle
CPUWeight=10
IOWeight=10
OOMScoreAdjust=500
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/xray-user-monitor
ReadOnlyPaths=/opt/xray-user-monitor
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
LockPersonality=true

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now xray-user-monitor.service

sleep 2

echo
echo "============================================================"
echo "Xray User Monitor installed"
echo "============================================================"
echo "Service : xray-user-monitor.service"
echo "Config  : $CONF_FILE"
echo "Database: $DATA_DIR/history.db"
echo "Events  : $DATA_DIR/events.log"
echo
echo "Useful commands:"
echo "  systemctl status xray-user-monitor --no-pager"
echo "  journalctl -u xray-user-monitor -f"
echo "  xraymon status"
echo "  xraymon events 168"
echo "  xraymon top 24"
echo "  xraymon show <EVENT-ID>"
echo "  xraymon user <USERNAME> 24"
echo "  xraymon size"
echo "  watch -n 5 xraymon status"
echo
echo "Current service status:"
systemctl --no-pager --full status xray-user-monitor.service || true
