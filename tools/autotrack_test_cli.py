#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import sys
import threading
import time
import uuid
from dataclasses import dataclass, field
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse


ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / "tools" / "test_bridge_config.json"


@dataclass
class BridgeState:
    command: dict[str, Any] | None = None
    command_claimed: bool = False
    command_logged: bool = False
    result: dict[str, Any] | None = None
    plugin_seen_at: float | None = None
    plugin_name: str | None = None
    lock: threading.Lock = field(default_factory=threading.Lock)


def load_config() -> dict[str, Any]:
    return json.loads(CONFIG_PATH.read_text())


def build_handler(state: BridgeState):
    class Handler(BaseHTTPRequestHandler):
        server_version = "AutoTrackBridge/1.0"

        def _read_json(self) -> dict[str, Any]:
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length) if length > 0 else b"{}"
            if not raw:
                return {}
            return json.loads(raw.decode("utf-8"))

        def _write_json(self, status: int, payload: dict[str, Any]) -> None:
            body = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:  # noqa: N802
            parsed = urlparse(self.path)
            if parsed.path == "/health":
                with state.lock:
                    payload = {
                        "ok": True,
                        "plugin_seen": state.plugin_seen_at is not None,
                        "plugin_name": state.plugin_name,
                        "command_pending": state.command is not None and not state.command_claimed,
                        "result_ready": state.result is not None,
                    }
                self._write_json(HTTPStatus.OK, payload)
                return

            if parsed.path == "/poll":
                query = parse_qs(parsed.query)
                plugin_name = query.get("plugin_name", ["unknown"])[0]
                with state.lock:
                    state.plugin_seen_at = time.time()
                    state.plugin_name = plugin_name
                    if state.command is not None and not state.command_claimed:
                        state.command_claimed = True
                        payload = {"ok": True, "command": state.command}
                    else:
                        payload = {"ok": True, "command": None}
                self._write_json(HTTPStatus.OK, payload)
                return

            self._write_json(HTTPStatus.NOT_FOUND, {"ok": False, "message": "not found"})

        def do_POST(self) -> None:  # noqa: N802
            parsed = urlparse(self.path)
            if parsed.path != "/result":
                self._write_json(HTTPStatus.NOT_FOUND, {"ok": False, "message": "not found"})
                return

            try:
                payload = self._read_json()
            except json.JSONDecodeError as exc:
                self._write_json(HTTPStatus.BAD_REQUEST, {"ok": False, "message": f"invalid json: {exc}"})
                return

            with state.lock:
                expected_id = state.command["id"] if state.command else None
                if payload.get("id") != expected_id:
                    self._write_json(
                        HTTPStatus.BAD_REQUEST,
                        {"ok": False, "message": "result id mismatch"},
                    )
                    return
                state.result = payload

            self._write_json(HTTPStatus.OK, {"ok": True})

        def log_message(self, format: str, *args: Any) -> None:
            return

    return Handler


def start_server(config: dict[str, Any], state: BridgeState) -> tuple[ThreadingHTTPServer, threading.Thread]:
    server = ThreadingHTTPServer(
        (config["listen_host"], int(config["listen_port"])),
        build_handler(state),
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread


def print_suite_list(config: dict[str, Any]) -> int:
    for suite_name in sorted(config["suites"].keys()):
        boot_mode = config["suites"][suite_name]["boot_mode"]
        print(f"{suite_name}\t{boot_mode}")
    return 0


def print_summary(result: dict[str, Any]) -> None:
    print(f"status: {result.get('status', 'unknown')}")
    print(
        "counts: "
        f"pass={result.get('pass_count', 0)} "
        f"fail={result.get('fail_count', 0)} "
        f"error={result.get('error_count', 0)}"
    )
    message = result.get("message")
    if message:
        print(f"message: {message}")

    lines = result.get("lines") or []
    if lines:
        print("lines:")
        for line in lines:
            print(f"  {line}")


def run_suite(config: dict[str, Any], suite_name: str) -> int:
    suites = config["suites"]
    if suite_name not in suites:
        print(f"Unknown suite: {suite_name}", file=sys.stderr)
        print("Run `make test-list` to see valid suites.", file=sys.stderr)
        return 2

    defaults = config["timeouts"]
    command = {
        "id": f"{suite_name}-{uuid.uuid4().hex[:10]}",
        "suite": suite_name,
        "boot_mode": suites[suite_name]["boot_mode"],
        "runner_ready_seconds": defaults["runner_ready_seconds"],
        "baseline_ready_seconds": defaults["baseline_ready_seconds"],
        "suite_seconds": defaults["suite_seconds"],
    }

    state = BridgeState(command=command)
    try:
        server, thread = start_server(config, state)
    except OSError as exc:
        print(f"Failed to bind localhost bridge: {exc}", file=sys.stderr)
        return 2

    print(
        f"Waiting for Studio plugin on "
        f"http://{config['listen_host']}:{config['listen_port']} for {suite_name}..."
    )

    start = time.time()
    plugin_connected = False
    plugin_timeout = defaults["plugin_connect_seconds"]
    suite_timeout = defaults["suite_seconds"] + defaults["baseline_ready_seconds"] + defaults["runner_ready_seconds"] + 20
    exit_code = 3

    try:
        while True:
            time.sleep(0.25)
            now = time.time()
            with state.lock:
                if state.plugin_seen_at is not None and not plugin_connected:
                    plugin_connected = True
                    print(f"Plugin connected: {state.plugin_name or 'unknown'}")

                if state.command_claimed and plugin_connected and not state.command_logged:
                    print(f"Running {suite_name} in {command['boot_mode']} mode...")
                    state.command_logged = True

                if state.result is not None:
                    result = state.result
                    print_summary(result)
                    status = result.get("status")
                    if status == "passed":
                        exit_code = 0
                    elif status == "failed":
                        exit_code = 1
                    else:
                        exit_code = 2
                    break

            if not plugin_connected and now - start > plugin_timeout:
                print(
                    "Studio bridge did not connect. Ensure the AutoTrack test bridge plugin is installed, "
                    "enabled, and allowed to access localhost.",
                    file=sys.stderr,
                )
                exit_code = 3
                break

            if now - start > suite_timeout:
                print(f"Timed out waiting for suite result: {suite_name}", file=sys.stderr)
                exit_code = 3
                break
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=1)

    return exit_code


def main() -> int:
    config = load_config()

    parser = argparse.ArgumentParser(description="AutoTrack local Studio test bridge")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("list", help="List supported suites")

    run_parser = subparsers.add_parser("run", help="Run a suite through the local Studio bridge")
    run_parser.add_argument("suite", help="Suite name, for example phase6_integration")

    args = parser.parse_args()

    if args.command == "list":
        return print_suite_list(config)
    if args.command == "run":
        return run_suite(config, args.suite)
    return 2


if __name__ == "__main__":
    sys.exit(main())
