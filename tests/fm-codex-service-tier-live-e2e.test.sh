#!/usr/bin/env bash
# Live guard for the codex launch's Standard service tier.
#
# Codex's model catalog advertises default_service_tier "priority" (Fast, billed
# at a higher plan-usage rate), and an operator can also prefer Fast in
# config.toml. The launch template in bin/fm-spawn.sh therefore pins
# service_tier="default", codex's explicit-Standard sentinel. An unrecognized
# config key is silently ignored rather than rejected, so a codex release that
# renamed the key would quietly bring Fast back; only the installed codex can say
# whether the override still lands.
#
# The guard replays the REAL launch flags fm-spawn builds - captured from a
# spawn driven through a fake pane - against the installed codex's app-server,
# whose thread/start reports the effective service tier. It runs against a
# throwaway CODEX_HOME whose config.toml prefers Fast, so it proves the launch
# beats that preference without reading or writing the operator's ~/.codex.
# A control run without the override must read back the Fast preference, which
# keeps the guard from passing on a probe that cannot see the tier at all.
#
# It spends no model tokens (thread/start opens no turn and needs no login), so
# it runs by default wherever codex is installed.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate default-on FM_CODEX_SERVICE_TIER_LIVE codex python3

CODEX_VERSION=$(codex --version 2>&1)
TMP_ROOT=$(fm_test_tmproot fm-codex-service-tier-live)
STANDARD_FLAG='-c "service_tier=\"default\""'

# capture_codex_launch <name> <extra fm-spawn args...>: spawns a codex crewmate
# against a fake pane and echoes the literal launch command firstmate sent.
capture_codex_launch() {
  local name=$1
  shift
  local case_dir home proj wt fakebin launchlog id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  id="codex-service-tier-$name"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  : > "$launchlog"
  FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" "$@" >/dev/null 2>&1 ||
    fail "codex $CODEX_VERSION: fm-spawn could not build a crewmate launch"
  cat "$launchlog"
}

# codex_global_flags <launch command>: the flags between the codex executable
# and the positional brief, which is everything codex itself is configured by.
codex_global_flags() {
  local launch=$1 flags
  flags=${launch#*codex }
  flags=${flags%%\"\$(*}
  printf '%s' "$flags"
}

# effective_service_tier <codex home> <cwd> <flags>: starts the installed
# codex's app-server with <flags> and prints the service tier thread/start
# reports, as JSON (a quoted string, or null for none).
effective_service_tier() {
  local codex_home=$1 cwd=$2 flags=$3
  eval "set -- $flags"
  CODEX_HOME="$codex_home" python3 - "$cwd" codex "$@" app-server <<'PY'
import json, os, queue, signal, subprocess, sys, tempfile, threading, time

cwd, argv = sys.argv[1], sys.argv[2:]
stderr = tempfile.TemporaryFile(mode="w+")
proc = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=stderr, text=True, bufsize=1, start_new_session=True)
lines = queue.Queue()

def pump():
    for line in proc.stdout:
        lines.put(line)
    lines.put(None)

threading.Thread(target=pump, daemon=True).start()

def send(message):
    proc.stdin.write(json.dumps(message) + "\n")
    proc.stdin.flush()

def reply(request_id, timeout=60):
    deadline = time.monotonic() + timeout
    try:
        while True:
            line = lines.get(timeout=max(0, deadline - time.monotonic()))
            if line is None:
                break
            message = json.loads(line)
            if message.get("id") == request_id:
                return message
    except queue.Empty:
        sys.exit("no reply to request %d: timed out" % request_id)
    proc.wait()
    stderr.seek(0)
    sys.exit("no reply to request %d: codex exited: %s" % (request_id, stderr.read()))

try:
    send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
          "params": {"clientInfo": {"name": "fm-service-tier-guard", "version": "0"}}})
    reply(1)
    send({"jsonrpc": "2.0", "method": "initialized"})
    send({"jsonrpc": "2.0", "id": 2, "method": "thread/start",
          "params": {"cwd": cwd, "ephemeral": True}})
    started = reply(2)
    if "result" not in started:
        sys.exit("thread/start failed: %s" % json.dumps(started.get("error")))
    print(json.dumps(started["result"].get("serviceTier")))
finally:
    # Reap codex and every helper it spawned before the fixture root is
    # removed, or their late state writes race the cleanup.
    try:
        os.killpg(proc.pid, signal.SIGTERM)
        proc.wait(timeout=10)
    except (ProcessLookupError, subprocess.TimeoutExpired):
        pass
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    proc.wait()
PY
}

test_installed_codex_runs_the_captured_crewmate_launch_at_standard_speed() {
  local launch flags control_flags codex_home cwd tier control
  launch=$(capture_codex_launch ship --mode no-mistakes --yolo off --model gpt-5.6-sol --effort high)
  flags=$(codex_global_flags "$launch")
  case "$flags" in
    *"$STANDARD_FLAG"*) ;;
    *) fail "codex $CODEX_VERSION: firstmate's crewmate launch carries no Standard service-tier override: $flags" ;;
  esac
  control_flags=${flags/"$STANDARD_FLAG"/}

  # An operator preference for Fast, isolated from the real ~/.codex.
  codex_home="$TMP_ROOT/codex-home"
  cwd="$TMP_ROOT/cwd"
  mkdir -p "$codex_home" "$cwd"
  printf 'service_tier = "priority"\n' > "$codex_home/config.toml"

  control=$(effective_service_tier "$codex_home" "$cwd" "$control_flags" 2>&1) ||
    fail "codex $CODEX_VERSION could not report the service tier for the control launch: $control"
  [ "$control" = '"priority"' ] ||
    fail "codex $CODEX_VERSION did not read back the Fast preference without the override (got $control), so this probe cannot see the service tier"

  tier=$(effective_service_tier "$codex_home" "$cwd" "$flags" 2>&1) ||
    fail "codex $CODEX_VERSION rejected firstmate's crewmate launch flags: $tier"
  [ "$tier" = '"default"' ] ||
    fail "codex $CODEX_VERSION resolved service tier $tier for firstmate's crewmate launch, so workers can run at Fast speed"

  printf 'ok - codex %s runs a firstmate crewmate launch at Standard speed over a Fast preference\n' "$CODEX_VERSION"
}

test_installed_codex_runs_the_captured_crewmate_launch_at_standard_speed

echo "# all fm-codex-service-tier-live-e2e tests passed"
