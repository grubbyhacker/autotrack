#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import textwrap
import sys
import threading
import time
import uuid
from dataclasses import dataclass, field
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.error import URLError
from urllib.parse import parse_qs, urlparse
from urllib.request import urlopen


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


def get_existing_bridge_health(config: dict[str, Any]) -> dict[str, Any] | None:
    health_url = f"http://{config['listen_host']}:{config['listen_port']}/health"
    try:
        with urlopen(health_url, timeout=1.0) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except (URLError, TimeoutError, json.JSONDecodeError, OSError):
        return None

    if payload.get("ok") is not True:
        return None
    return payload


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


def eprint(message: str) -> None:
    print(message, file=sys.stderr)


def _trim_text(value: Any, max_chars: int = 160) -> str:
    if value is None:
        return ""

    if isinstance(value, str):
        text = value
    else:
        text = json.dumps(value, sort_keys=True)

    text = " ".join(text.split())
    if len(text) <= max_chars:
        return text
    return text[: max_chars - 3] + "..."


def _prompt_summary(kind: str, payload: dict[str, Any]) -> str:
    if kind == "propose":
        request = payload.get("request") or {}
        parsed = request.get("parsed") or {}
        parts = []
        if request.get("request_id"):
            parts.append(f"request={request['request_id']}")
        if parsed.get("sector_id") is not None:
            parts.append(f"sector={parsed['sector_id']}")
        if parsed.get("mechanic"):
            parts.append(f"mechanic={parsed['mechanic']}")
        if request.get("raw_text"):
            parts.append(f'text="{_trim_text(request["raw_text"], 80)}"')
        return ", ".join(parts) if parts else _trim_text(payload)

    if kind == "repair":
        packet = payload.get("packet") or {}
        failure = packet.get("failure") or {}
        parts = []
        if packet.get("attempt") is not None:
            parts.append(f"attempt={packet['attempt']}")
        if failure.get("type"):
            parts.append(f"failure={failure['type']}")
        if failure.get("sector_id") is not None:
            parts.append(f"sector={failure['sector_id']}")
        return ", ".join(parts) if parts else _trim_text(payload)

    if kind == "orchestrate":
        context = payload.get("context") or {}
        track_intent = context.get("track_intent") or {}
        parts = []
        if context.get("decision_index") is not None:
            parts.append(f"decision_index={context['decision_index']}")
        if track_intent.get("target_total_score") is not None:
            parts.append(f"score={track_intent['target_total_score']:.2f}")
        diversity = track_intent.get("diversity_pressure") or {}
        if diversity:
            parts.append(f"diversity_keys={len(diversity)}")
        return ", ".join(parts) if parts else _trim_text(payload)

    return _trim_text(payload)


def _decoded_summary(kind: str, payload: dict[str, Any]) -> str:
    decoded = payload.get("decoded_response")
    if not isinstance(decoded, dict):
        return _trim_text(decoded)

    if kind == "orchestrate":
        parts = []
        action = decoded.get("action")
        if action:
            parts.append(f"action={action}")
        if decoded.get("sector_id") is not None:
            parts.append(f"sector={decoded['sector_id']}")
        if decoded.get("mechanic"):
            parts.append(f"mechanic={decoded['mechanic']}")
        if decoded.get("params_hint"):
            parts.append(f'hint="{_trim_text(decoded["params_hint"], 80)}"')
        return ", ".join(parts) if parts else _trim_text(decoded)

    if kind == "propose":
        parts = []
        if decoded.get("sector_id") is not None:
            parts.append(f"sector={decoded['sector_id']}")
        if decoded.get("mechanic"):
            parts.append(f"mechanic={decoded['mechanic']}")
        pads = decoded.get("pads")
        if isinstance(pads, dict) and pads:
            parts.append(f"pads={_trim_text(pads, 80)}")
        params = decoded.get("params")
        if isinstance(params, dict) and params:
            parts.append(f"params={_trim_text(params, 120)}")
        return ", ".join(parts) if parts else _trim_text(decoded)

    if kind == "repair":
        parts = []
        action = decoded.get("action")
        if isinstance(action, dict):
            parts.append(f"action={_trim_text(action, 120)}")
        if decoded.get("explanation"):
            parts.append(f'explanation="{_trim_text(decoded["explanation"], 100)}"')
        if decoded.get("newState") is not None:
            parts.append("newState=yes")
        return ", ".join(parts) if parts else _trim_text(decoded)

    return _trim_text(decoded)


def _prompt_message_lines(payload: dict[str, Any], max_chars: int) -> list[str]:
    lines: list[str] = []

    messages = payload.get("messages")
    if isinstance(messages, list):
        for index, message in enumerate(messages, start=1):
            if not isinstance(message, dict):
                continue
            role = message.get("role") or f"message{index}"
            content = _trim_text(message.get("content"), max_chars)
            if content:
                lines.append(f"{role}: {content}")

    system_prompt = payload.get("system_prompt")
    if system_prompt:
        lines.append(f"system: {_trim_text(system_prompt, max_chars)}")

    user_prompt = payload.get("user_prompt")
    if user_prompt:
        lines.append(f"user: {_trim_text(user_prompt, max_chars)}")

    return lines


def inspect_llm_trace(trace_path: str, show_raw: bool, max_chars: int) -> int:
    try:
        with open(trace_path, "r", encoding="utf-8") as handle:
            export = json.load(handle)
    except FileNotFoundError:
        eprint(f"Trace file not found: {trace_path}")
        return 2
    except json.JSONDecodeError as exc:
        eprint(f"Trace file is not valid JSON: {exc}")
        return 2

    if not isinstance(export, dict):
        eprint("Trace export must be a JSON object.")
        return 2

    events = export.get("events")
    if not isinstance(events, list):
        eprint("Trace export is missing an events array.")
        return 2

    calls: list[dict[str, Any]] = []
    current: dict[str, Any] | None = None
    for event in events:
        if not isinstance(event, dict):
            continue
        if event.get("direction") == "prompt" or current is None:
            current = {
                "seq_start": event.get("seq"),
                "seq_end": event.get("seq"),
                "kind": event.get("kind"),
                "role": event.get("role"),
                "provider": event.get("provider"),
                "model": event.get("model"),
                "events": [event],
            }
            calls.append(current)
        else:
            current["seq_end"] = event.get("seq")
            current["events"].append(event)

    print(
        f"run_id={export.get('run_id')} mode={export.get('mode', 'unknown')} "
        f"owner={export.get('owner', 'unknown')} event_count={export.get('event_count', len(events))} "
        f"logical_calls={len(calls)}"
    )
    if export.get("started_at_ms") is not None:
        finished = export.get("finished_at_ms")
        status = "finished" if finished is not None else "active"
        print(f"run_status={status} started_at_ms={export.get('started_at_ms')} finished_at_ms={finished}")

    for index, call in enumerate(calls, start=1):
        print()
        print(
            f"[{index}] seq={call['seq_start']}-{call['seq_end']} "
            f"kind={call.get('kind')} role={call.get('role')} model={call.get('model')}"
        )

        raw_printed = False
        for event in call["events"]:
            payload = event.get("payload") or {}
            direction = event.get("direction")
            stage = payload.get("stage")

            if direction == "prompt":
                line = _prompt_summary(call.get("kind") or "", payload)
                print(textwrap.indent(f"prompt: {line}", "  "))
                prompt_lines = _prompt_message_lines(payload, max_chars)
                for prompt_line in prompt_lines:
                    print(textwrap.indent(prompt_line, "    "))
            elif direction == "response" and stage == "decoded":
                line = _decoded_summary(call.get("kind") or "", payload)
                print(textwrap.indent(f"decoded: {line}", "  "))
                if show_raw and payload.get("raw_response") is not None and not raw_printed:
                    print(textwrap.indent(f"raw: {_trim_text(payload.get('raw_response'), max_chars)}", "  "))
                    raw_printed = True
            elif direction == "response" and stage == "raw":
                if show_raw:
                    print(textwrap.indent(f"raw: {_trim_text(payload.get('raw_response'), max_chars)}", "  "))
                    raw_printed = True
            elif direction == "error":
                stage_name = payload.get("stage") or "unknown"
                print(textwrap.indent(f"error[{stage_name}]: {_trim_text(payload.get('error'), max_chars)}", "  "))

    return 0


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
        "boot_ready_seconds": defaults.get("boot_ready_seconds", 30),
        "baseline_ready_seconds": defaults["baseline_ready_seconds"],
        "suite_seconds": defaults["suite_seconds"],
    }

    state = BridgeState(command=command)
    try:
        server, thread = start_server(config, state)
    except OSError as exc:
        existing_bridge = get_existing_bridge_health(config)
        if existing_bridge is not None:
            plugin_name = existing_bridge.get("plugin_name") or "unknown"
            result_ready = existing_bridge.get("result_ready") is True
            command_pending = existing_bridge.get("command_pending") is True
            if result_ready:
                status_detail = "an earlier suite already finished but its bridge process is still running"
            elif command_pending:
                status_detail = "another bridge-backed suite is queued and waiting for Studio"
            else:
                status_detail = "another bridge-backed suite is already running"
            eprint(
                "AutoTrack test bridge already in use on "
                f"http://{config['listen_host']}:{config['listen_port']} "
                f"({status_detail}; plugin={plugin_name}). "
                "Wait for the active suite to finish before starting another."
            )
            return 2

        eprint(f"Failed to bind localhost bridge: {exc}")
        return 2

    print(
        f"Waiting for Studio plugin on "
        f"http://{config['listen_host']}:{config['listen_port']} for {suite_name}..."
    )

    start = time.time()
    plugin_connected = False
    plugin_timeout = defaults["plugin_connect_seconds"]
    suite_timeout = (
        defaults["suite_seconds"]
        + defaults["baseline_ready_seconds"]
        + defaults["runner_ready_seconds"]
        + defaults.get("boot_ready_seconds", 30)
        + 20
    )
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
                eprint(f"Timed out waiting for suite result: {suite_name}")
                exit_code = 3
                break
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=1)

    return exit_code


def export_llm_trace(config: dict[str, Any]) -> int:
    defaults = config["timeouts"]
    command = {
        "id": f"export-llm-trace-{uuid.uuid4().hex[:10]}",
        "command_type": "export_llm_trace",
        "suite": "llm_trace_export",
        "boot_mode": "live_session",
        "runner_ready_seconds": defaults["runner_ready_seconds"],
        "boot_ready_seconds": defaults.get("boot_ready_seconds", 30),
        "baseline_ready_seconds": 0,
        "suite_seconds": 30,
    }

    state = BridgeState(command=command)
    try:
        server, thread = start_server(config, state)
    except OSError as exc:
        existing_bridge = get_existing_bridge_health(config)
        if existing_bridge is not None:
            plugin_name = existing_bridge.get("plugin_name") or "unknown"
            eprint(
                "AutoTrack test bridge already in use on "
                f"http://{config['listen_host']}:{config['listen_port']} "
                f"(plugin={plugin_name}). Wait for the active command to finish before exporting."
            )
            return 2

        eprint(f"Failed to bind localhost bridge: {exc}")
        return 2

    eprint(
        f"Waiting for Studio plugin on "
        f"http://{config['listen_host']}:{config['listen_port']} for export-llm-trace..."
    )

    start = time.time()
    plugin_connected = False
    plugin_timeout = defaults["plugin_connect_seconds"]
    command_timeout = 60
    exit_code = 3

    try:
        while True:
            time.sleep(0.25)
            now = time.time()
            with state.lock:
                if state.plugin_seen_at is not None and not plugin_connected:
                    plugin_connected = True
                    eprint(f"Plugin connected: {state.plugin_name or 'unknown'}")

                if state.command_claimed and plugin_connected and not state.command_logged:
                    eprint("Requesting latest LLM trace from active Studio session...")
                    state.command_logged = True

                if state.result is not None:
                    result = state.result
                    if result.get("status") != "passed":
                        eprint(result.get("message") or "LLM trace export failed")
                        exit_code = 2
                        break

                    payload = result.get("payload") or {}
                    export = payload.get("llm_trace_export")
                    if not isinstance(export, dict):
                        eprint("No LLM trace export available in the active Studio session.")
                        exit_code = 4
                        break

                    sys.stdout.write(json.dumps(export))
                    sys.stdout.write("\n")
                    exit_code = 0
                    break

            if not plugin_connected and now - start > plugin_timeout:
                eprint(
                    "Studio bridge did not connect. Ensure the AutoTrack test bridge plugin is installed, "
                    "enabled, and allowed to access localhost."
                )
                exit_code = 3
                break

            if now - start > command_timeout:
                eprint("Timed out waiting for LLM trace export.")
                exit_code = 3
                break
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=1)

    return exit_code


def endurance_trace(config: dict[str, Any], model: str, duration: int, out_path: str | None) -> int:
    defaults = config["timeouts"]
    command = {
        "id": f"endurance-trace-{uuid.uuid4().hex[:10]}",
        "command_type": "endurance_trace",
        "suite": "endurance_trace",
        "boot_mode": "baseline",
        "llm_enabled": True,
        "llm_model": model,
        "trace_duration_seconds": duration,
        "runner_ready_seconds": defaults["runner_ready_seconds"],
        "baseline_ready_seconds": defaults["baseline_ready_seconds"],
        "suite_seconds": max(defaults["suite_seconds"], duration + defaults["baseline_ready_seconds"] + 60),
    }

    state = BridgeState(command=command)
    try:
        server, thread = start_server(config, state)
    except OSError as exc:
        existing_bridge = get_existing_bridge_health(config)
        if existing_bridge is not None:
            plugin_name = existing_bridge.get("plugin_name") or "unknown"
            eprint(
                "AutoTrack test bridge already in use on "
                f"http://{config['listen_host']}:{config['listen_port']} "
                f"(plugin={plugin_name}). Wait for the active command to finish before starting endurance-trace."
            )
            return 2

        eprint(f"Failed to bind localhost bridge: {exc}")
        return 2

    eprint(
        f"Waiting for Studio plugin on "
        f"http://{config['listen_host']}:{config['listen_port']} for endurance-trace..."
    )

    start = time.time()
    plugin_connected = False
    plugin_timeout = defaults["plugin_connect_seconds"]
    command_timeout = duration + defaults["baseline_ready_seconds"] + defaults["runner_ready_seconds"] + 120
    exit_code = 3

    try:
        while True:
            time.sleep(0.25)
            now = time.time()
            with state.lock:
                if state.plugin_seen_at is not None and not plugin_connected:
                    plugin_connected = True
                    eprint(f"Plugin connected: {state.plugin_name or 'unknown'}")

                if state.command_claimed and plugin_connected and not state.command_logged:
                    eprint(f"Running endurance trace with model {model} for {duration}s...")
                    state.command_logged = True

                if state.result is not None:
                    result = state.result
                    if result.get("status") != "passed":
                        print_summary(result)
                        exit_code = 2
                        break

                    payload = result.get("payload") or {}
                    export = payload.get("llm_trace_export")
                    if not isinstance(export, dict):
                        eprint("No LLM trace export available in the endurance result.")
                        exit_code = 4
                        break

                    rendered = json.dumps(export)
                    if out_path:
                        parent = os.path.dirname(out_path)
                        if parent:
                            os.makedirs(parent, exist_ok=True)
                        with open(out_path, "w", encoding="utf-8") as handle:
                            handle.write(rendered)
                            handle.write("\n")
                        eprint(f"Wrote endurance trace to {out_path}")
                    else:
                        sys.stdout.write(rendered)
                        sys.stdout.write("\n")

                    exit_code = 0
                    break

            if not plugin_connected and now - start > plugin_timeout:
                eprint(
                    "Studio bridge did not connect. Ensure the AutoTrack test bridge plugin is installed, "
                    "enabled, and allowed to access localhost."
                )
                exit_code = 3
                break

            if now - start > command_timeout:
                eprint("Timed out waiting for endurance trace export.")
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

    subparsers.add_parser("export-llm-trace", help="Export the latest LLM trace JSON from an active Studio session")

    endurance_parser = subparsers.add_parser(
        "endurance-trace",
        help="Boot Studio, start endurance mode with a specific model, and export the resulting LLM trace JSON",
    )
    endurance_parser.add_argument("--model", required=True, help="LLM model id, for example google/gemma-3-4b-it")
    endurance_parser.add_argument("--duration", type=int, default=60, help="How long to let endurance mode run before exporting")
    endurance_parser.add_argument("--out", help="Optional file path to write the exported JSON trace")

    inspect_parser = subparsers.add_parser(
        "inspect-llm-trace",
        help="Read an exported LLM trace JSON file and print logical-call summaries",
    )
    inspect_parser.add_argument("trace_path", help="Path to an exported LLM trace JSON file")
    inspect_parser.add_argument("--show-raw", action="store_true", help="Include raw response snippets in the output")
    inspect_parser.add_argument("--max-chars", type=int, default=160, help="Maximum characters to print for raw snippets")

    args = parser.parse_args()

    if args.command == "list":
        return print_suite_list(config)
    if args.command == "run":
        return run_suite(config, args.suite)
    if args.command == "export-llm-trace":
        return export_llm_trace(config)
    if args.command == "endurance-trace":
        return endurance_trace(config, args.model, args.duration, args.out)
    if args.command == "inspect-llm-trace":
        return inspect_llm_trace(args.trace_path, args.show_raw, args.max_chars)
    return 2


if __name__ == "__main__":
    sys.exit(main())
