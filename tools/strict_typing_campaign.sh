#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
STATE="${1:-plans/strict_typing_campaign_state.md}"
MAX_SECONDS="${MAX_SECONDS:-14400}"
MAX_INVOCATIONS="${MAX_INVOCATIONS:-40}"
WORKER_TIMEOUT_SECONDS="${WORKER_TIMEOUT_SECONDS:-600}"
NO_PROGRESS_LIMIT="${NO_PROGRESS_LIMIT:-3}"
CODEX_CMD="${CODEX_CMD:-codex}"
LOG_DIR="logs/strict_typing_workers"
CAMPAIGN_LOG="logs/strict_typing_campaign.log"
START_EPOCH="$(date +%s)"
mkdir -p "$LOG_DIR"

ts() { date +"%Y-%m-%dT%H:%M:%S%z"; }
notify() {
	local title="$1" body="$2"
	if command -v powershell.exe >/dev/null 2>&1; then
		MSG_TITLE="$title" MSG_BODY="$body" powershell.exe -NoProfile -Command \
			"[reflection.assembly]::LoadWithPartialName('System.Windows.Forms') > \$null; [System.Windows.Forms.MessageBox]::Show(\$env:MSG_BODY, \$env:MSG_TITLE) > \$null" \
			>/dev/null 2>&1 &
	else
		printf '\a[%s] %s\n' "$title" "$body" >&2
	fi
}
geth() { grep -m1 "^$1:" "$STATE" | sed "s/^$1:[[:space:]]*//" || true; }
seth() {
	local key="$1" value="$2" tmp
	tmp="$(mktemp)"
	awk -v key="$key" -v value="$value" '$0 ~ "^" key ":" { print key ": " value; done = 1; next } { print } END { if (!done) print key ": " value }' "$STATE" > "$tmp"
	mv "$tmp" "$STATE"
}
strict_count() {
	if command -v rg >/dev/null 2>&1; then
		rg -l '^--!strict' src studio --glob '*.luau' | wc -l | tr -d ' '
	else
		find src studio -type f -name '*.luau' -exec grep -l '^--!strict' {} + | wc -l | tr -d ' '
	fi
}
qcount() { awk '/^## Queue/ { q = 1; next } /^## / && q { exit } q && /^[0-9]+[.][[:space:]]/ { n++ } END { print n + 0 }' "$STATE"; }
qline() {
	awk -v i="$1" '/^## Queue/ { q = 1; next } /^## / && q { exit } q && $0 ~ "^" i "[.][[:space:]]" { print; exit }' "$STATE"
}
qfile() { printf '%s\n' "$1" | sed -E 's/^[0-9]+[.][[:space:]]*([^|]+).*/\1/' | sed 's/[[:space:]]*$//'; }
dirty_other() {
	local rel
	rel="$(realpath --relative-to="$ROOT" "$STATE" 2>/dev/null || printf '%s' "$STATE")"
	git status --porcelain --untracked-files=all | while IFS= read -r line; do
		path="${line:3}"
		case "$path" in "$rel"|logs/*) ;; *) printf '%s\n' "$line" ;; esac
	done
}
require_clean() {
	local dirty
	dirty="$(dirty_other)"
	[[ -z "$dirty" ]] && return
	seth STATUS error
	seth STOP_REASON "dirty worktree outside campaign state/logs"
	printf '%s\n' "$dirty" >&2
	notify "AutoTrack strict campaign worker error" "Dirty worktree outside campaign state/logs. See terminal output."
	exit 1
}
hist() {
	if grep -q '^## History' "$STATE"; then printf '%s\n' "$1" >> "$STATE"; else printf '\n## History\n%s\n' "$1" >> "$STATE"; fi
}
terminal() {
	local status="$1" reason="$2" title="$3" body="$4"
	seth STATUS "$status"
	[[ -n "$reason" ]] && seth STOP_REASON "$reason"
	hist "$(ts) | orchestrator | result=$status | reason=$reason"
	notify "$title" "$body"
	exit 0
}
prompt() {
	cat <<PROMPT
You are one worker in a serial AutoTrack strict-typing migration campaign.

Read $STATE. It is the durable shared memory. Keep updates concise for the next worker.

Authority:
- Attempt EXACTLY ONE file: the queue item at NEXT_INDEX.
- Flip only that file to the next typing tier; unmarked Luau files normally become --!strict.
- Make the smallest local edits needed for that one file to pass checks.
- Do not use Roblox MCP or Studio. Do not retune gameplay or intentionally alter runtime behavior.
- No \`:: any\` casts. Do not widen exported/module-boundary types; STOP instead.
- Nil checks, local narrowing, local aliases, and helper constructors are allowed.
- If a runtime-vs-test/helper input type split is needed for the first time, STOP.

Procedure:
1. Confirm git is clean except for $STATE and logs/. If not, append STOP-NEEDS-HUMAN with dirty paths and exit.
2. Read NEXT_INDEX and select exactly that queue file.
3. Inspect only the target file and minimal directly required type/config files.
4. Edit the target file only unless a tiny same-file-adjacent test/check update is required. If broader edits are needed, revert and STOP.
5. Run at minimum \`make typecheck\`, plus listed queue checks when relevant and not Studio/live-session dependent.
6. On success: commit only migrated source/test changes, not state/logs, as \`strict: promote <path>\`; update STRICT_CURRENT, increment NEXT_INDEX, append one History line, and exit.
7. On failure: revert target edits, leave git clean except for state/logs, increment NEXT_INDEX, append \`failure_reverted\`, and exit.
8. On policy boundary: leave target unflipped, clean up edits, set STATUS: stop and STOP_REASON beginning \`STOP-NEEDS-HUMAN:\`, append one History line, and exit.

Final response max five lines: attempted file, result, checks, commit hash if any, STOP status.
PROMPT
}

[[ -f "$STATE" ]] || { echo "Missing state file: $STATE" >&2; exit 2; }
require_clean
while true; do
	status="$(geth STATUS || true)"
	stop_reason="$(geth STOP_REASON || true)"
	if [[ "$status" == "stop" || "$stop_reason" == STOP-NEEDS-HUMAN:* ]]; then
		terminal stop "$stop_reason" "AutoTrack strict campaign STOP" "Human review needed: $stop_reason"
	fi
	[[ "$status" == "running" ]] || exit 0
	next_index="$(geth NEXT_INDEX)"
	invocations="$(geth INVOCATIONS_STARTED)"
	no_progress="$(geth NO_PROGRESS_COUNT)"
	strict_start="$(geth STRICT_START)"
	total="$(qcount)"
	elapsed="$(( $(date +%s) - START_EPOCH ))"
	[[ "$next_index" =~ ^[0-9]+$ && "$invocations" =~ ^[0-9]+$ && "$no_progress" =~ ^[0-9]+$ ]] \
		|| terminal error "state header has nonnumeric counters" "AutoTrack strict campaign worker error" "State counters are corrupt in $STATE."
	(( next_index > total )) && terminal complete "queue complete" "AutoTrack strict campaign complete" "Queue complete. Strict $strict_start -> $(strict_count). See $STATE."
	(( elapsed >= MAX_SECONDS )) && terminal budget_exhausted "wall clock budget exhausted" "AutoTrack strict campaign budget exhausted" "Stopped after $invocations invocations, $elapsed seconds, strict $strict_start -> $(strict_count)."
	(( invocations >= MAX_INVOCATIONS )) && terminal budget_exhausted "invocation budget exhausted" "AutoTrack strict campaign budget exhausted" "Stopped after $invocations invocations, $elapsed seconds, strict $strict_start -> $(strict_count)."
	(( no_progress >= NO_PROGRESS_LIMIT )) && terminal no_progress "no progress for $no_progress iterations" "AutoTrack strict campaign no progress" "Stopped after $no_progress non-progress workers. Next file: $(qfile "$(qline "$next_index")")."

	line="$(qline "$next_index")"
	[[ -n "$line" ]] || terminal error "missing queue entry for NEXT_INDEX=$next_index" "AutoTrack strict campaign worker error" "State queue is missing NEXT_INDEX=$next_index."
	target="$(qfile "$line")"
	before_commit="$(git rev-parse HEAD)"
	before_strict="$(strict_count)"
	log_file="$LOG_DIR/$(date +%Y%m%d-%H%M%S)-$next_index.log"
	printf '%s | launch index=%s file=%s commit=%s strict=%s elapsed=%s\n' "$(ts)" "$next_index" "$target" "$before_commit" "$before_strict" "$elapsed" >> "$CAMPAIGN_LOG"
	set +e
	prompt | timeout "$WORKER_TIMEOUT_SECONDS" "$CODEX_CMD" --ask-for-approval never exec --cd "$ROOT" --sandbox danger-full-access - 2>&1 | tee "$log_file"
	worker_status=${PIPESTATUS[1]}
	set -e
	require_clean
	after_commit="$(git rev-parse HEAD)"
	after_strict="$(strict_count)"
	seth STRICT_CURRENT "$after_strict"
	seth INVOCATIONS_STARTED "$((invocations + 1))"
	stop_reason="$(geth STOP_REASON || true)"
	if [[ "$(geth STATUS || true)" == "stop" || "$stop_reason" == STOP-NEEDS-HUMAN:* ]]; then
		terminal stop "$stop_reason" "AutoTrack strict campaign STOP" "Human review needed at NEXT_INDEX=$next_index: $stop_reason"
	fi
	(( worker_status == 0 )) || terminal error "worker exited with status $worker_status at index $next_index" "AutoTrack strict campaign worker error" "Worker failed or timed out at NEXT_INDEX=$next_index. Worktree check required."
	if [[ "$after_commit" != "$before_commit" && "$after_strict" -gt "$before_strict" ]]; then
		seth NO_PROGRESS_COUNT 0
	else
		seth NO_PROGRESS_COUNT "$((no_progress + 1))"
	fi
done
