#!/usr/bin/env python3

import argparse
import csv
import json
import os
import socket
import sys
import time
from typing import Dict, List


DEFAULT_SOCKET_PATH = os.environ.get("HAPROXY_SOCKET_PATH", "/var/run/haproxy.sock")


class Colors:
    BOLD = "\033[1m"
    DIM = "\033[2m"
    RED = "\033[31m"
    GREEN = "\033[32m"
    YELLOW = "\033[33m"
    BLUE = "\033[34m"
    CYAN = "\033[36m"
    RESET = "\033[0m"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="haproxy-state",
        description="Show HAProxy frontend, backend, and server state in a readable format.",
    )
    parser.add_argument("--down", action="store_true", help="Show only unhealthy entries.")
    parser.add_argument("--json", action="store_true", help="Print JSON output.")
    parser.add_argument("--watch", type=int, help="Refresh output every N seconds.")
    parser.add_argument(
        "--socket",
        default=DEFAULT_SOCKET_PATH,
        help="Override HAProxy stats socket path.",
    )
    return parser.parse_args()


def color_enabled() -> bool:
    return sys.stdout.isatty() and os.environ.get("TERM") not in (None, "", "dumb")


def style(text: str, color: str) -> str:
    if not color_enabled():
        return text
    return f"{color}{text}{Colors.RESET}"


def fetch_stats(socket_path: str) -> str:
    if not os.path.exists(socket_path):
        raise FileNotFoundError(f"HAProxy socket not found: {socket_path}")

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.connect(socket_path)
        client.sendall(b"show stat\n")
        client.shutdown(socket.SHUT_WR)

        chunks: List[bytes] = []
        while True:
            chunk = client.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)

    return b"".join(chunks).decode("utf-8", errors="replace")


def load_rows(raw_stats: str) -> List[Dict[str, str]]:
    lines = [line for line in raw_stats.splitlines() if line.strip()]
    if not lines:
        return []

    header_line = next((line for line in lines if line.startswith("# ")), None)
    if header_line is None:
        return []

    field_names = header_line[2:].split(",")
    reader = csv.DictReader(
        [line for line in lines if not line.startswith("#")],
        fieldnames=field_names,
    )

    rows: List[Dict[str, str]] = []
    for row in reader:
        svname = row.get("svname", "")
        status = row.get("status", "")
        check_status = row.get("check_status") or row.get("check_desc") or "-"
        addr = row.get("addr", "-")
        sessions = int(row.get("scur") or 0)
        weight = row.get("weight", "-")
        entry_type = "server"
        if svname == "FRONTEND":
            entry_type = "frontend"
            check_status = "-"
            weight = "-"
        elif svname == "BACKEND":
            entry_type = "backend"
            weight = "-"

        rows.append(
            {
                "type": entry_type,
                "backend": row.get("pxname", ""),
                "server": svname,
                "address": addr,
                "status": status,
                "sessions": sessions,
                "weight": weight,
                "check_status": check_status,
            }
        )

    return rows


def normalize_name(row: Dict[str, str]) -> str:
    if row["type"] == "frontend":
        return row["backend"]
    if row["type"] == "backend":
        return row["backend"]
    return row["server"]


def status_category(status: str, entry_type: str = "server") -> str:
    if entry_type == "frontend" and status == "OPEN":
        return "up"
    if status.startswith("UP"):
        return "up"
    if status.startswith("DOWN") or status.startswith("NOLB"):
        return "down"
    return "other"


def status_chip(status: str, entry_type: str = "server") -> str:
    text = truncate(status, 11)
    category = status_category(status, entry_type)
    if category == "up":
        return style(f"{'OK':<4} {text:<11}", Colors.GREEN)
    if category == "down":
        return style(f"{'FAIL':<4} {text:<11}", Colors.RED)
    return style(f"{'WARN':<4} {text:<11}", Colors.YELLOW)


def summarize(rows: List[Dict[str, str]]) -> Dict[str, int]:
    summary = {"total": len(rows), "up": 0, "down": 0, "other": 0}
    for row in rows:
        summary[status_category(row["status"], row["type"])] += 1
    return summary


def truncate(value: str, width: int) -> str:
    if len(value) <= width:
        return value
    if width <= 1:
        return value[:width]
    return value[: width - 1] + "…"


def render_table(rows: List[Dict[str, str]], socket_path: str, only_down: bool) -> str:
    visible_rows = [
        row for row in rows if not only_down or status_category(row["status"], row["type"]) == "down"
    ]
    summary = summarize(rows)

    lines = [
        f"{style('HAProxy State', Colors.BOLD)}  {style(socket_path, Colors.DIM)}",
        "",
        "  ".join(
            [
                style(f"UP {summary['up']}", Colors.GREEN),
                style(f"DOWN {summary['down']}", Colors.RED),
                style(f"OTHER {summary['other']}", Colors.YELLOW),
                style(f"TOTAL {summary['total']}", Colors.CYAN),
            ]
        ),
        "",
    ]

    if not visible_rows:
        lines.append("No unhealthy entries found." if only_down else "No HAProxy entries found.")
        return "\n".join(lines)

    frontends = [row for row in visible_rows if row["type"] == "frontend"]
    servers = [row for row in visible_rows if row["type"] == "server"]

    if frontends:
        lines.append(style("Frontends", Colors.BOLD))
        frontend_headers = (
            ("Name", 24),
            ("Status", 16),
            ("Sess", 6),
        )
        lines.append("  " + "  ".join(label.ljust(width) for label, width in frontend_headers))
        lines.append("  " + "  ".join("-" * width for _, width in frontend_headers))
        for row in sorted(frontends, key=lambda item: item["backend"]):
            lines.append(
                "  "
                + "  ".join(
                    [
                        truncate(normalize_name(row), 24).ljust(24),
                        status_chip(row["status"], row["type"]),
                        str(row["sessions"]).rjust(6),
                    ]
                )
            )
        lines.append("")

    backend_rows = []
    for row in servers:
        backend_rows.append(
            {
                "backend": row["backend"],
                "name": normalize_name(row),
                "address": row["address"],
                "status": row["status"],
                "sessions": row["sessions"],
                "weight": row["weight"],
                "check_status": row["check_status"],
            }
        )

    if backend_rows:
        lines.append(style("Backends", Colors.BOLD))
        backend_headers = (
            ("Backend", 24),
            ("Name", 20),
            ("Address", 22),
            ("Status", 16),
            ("Sess", 6),
            ("Weight", 8),
            ("Check", 24),
        )
        lines.append("  " + "  ".join(label.ljust(width) for label, width in backend_headers))
        lines.append("  " + "  ".join("-" * width for _, width in backend_headers))
        for row in sorted(backend_rows, key=lambda item: (item["backend"], item["name"])):
            lines.append(
                "  "
                + "  ".join(
                    [
                        truncate(row["backend"], 24).ljust(24),
                        truncate(row["name"], 20).ljust(20),
                        truncate(row["address"], 22).ljust(22),
                        status_chip(row["status"], "server"),
                        str(row["sessions"]).rjust(6),
                        truncate(str(row["weight"]), 8).rjust(8),
                        truncate(row["check_status"], 24).ljust(24),
                    ]
                )
            )

    return "\n".join(lines)


def render_json(rows: List[Dict[str, str]], only_down: bool) -> str:
    visible_rows = [
        row for row in rows if not only_down or status_category(row["status"], row["type"]) == "down"
    ]
    normalized_rows = []
    for row in visible_rows:
        normalized = dict(row)
        normalized["name"] = normalize_name(row)
        normalized_rows.append(normalized)

    return json.dumps(normalized_rows, ensure_ascii=True, indent=2)


def main() -> int:
    args = parse_args()

    if args.watch is not None and args.watch <= 0:
        print("ERROR: --watch requires an integer interval greater than zero", file=sys.stderr)
        return 1

    if args.watch and args.json:
        print("ERROR: --watch and --json cannot be used together", file=sys.stderr)
        return 1

    try:
        while True:
            rows = load_rows(fetch_stats(args.socket))

            if args.json:
                output = render_json(rows, args.down)
            else:
                output = render_table(rows, args.socket, args.down)
                if args.watch:
                    print("\033[H\033[J", end="")

            print(output)

            if not args.watch:
                break
            time.sleep(args.watch)
    except (FileNotFoundError, ConnectionError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130

    return 0


if __name__ == "__main__":
    sys.exit(main())
