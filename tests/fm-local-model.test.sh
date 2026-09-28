#!/usr/bin/env bash
# Behavior tests for bin/fm-local-model.sh and the Pi launch gate it backs in
# bin/fm-spawn.sh.
#
# A real HTTP listener on 127.0.0.1 plays the local model server: it serves
# whatever model list and status the case writes, and logs every request so
# each case can prove the check only ever read the model list. A closed port
# and a listener that never answers cover the offline and silent-server cases
# with real curl timeouts. Spawn cases drive the real fm-spawn.sh through the
# shared fake tmux and assert a refusal leaves no task record and no launch.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TOOL="$ROOT/bin/fm-local-model.sh"
TMP_ROOT=$(fm_test_tmproot fm-local-model)
SERVER_DIR="$TMP_ROOT/server"
AGENT="$TMP_ROOT/agent"
SERVER_PIDS=()
LM_STATE="$TMP_ROOT/lm-home/state"
LM_CONFIG="$TMP_ROOT/lm-home/config"
unset PI_CODING_AGENT_DIR
export FM_LOCAL_MODEL_TIMEOUT=1
# The check counts this home's task records and reads its session limits.
export FM_STATE_OVERRIDE="$LM_STATE" FM_CONFIG_OVERRIDE="$LM_CONFIG"
mkdir -p "$SERVER_DIR" "$AGENT" "$LM_STATE" "$LM_CONFIG"

stop_servers() {
  local pid
  for pid in "${SERVER_PIDS[@]:-}"; do
    [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
  done
}
trap 'stop_servers; fm_test_cleanup' EXIT

# start_listener <mode> <port-file>: serve (answer from SERVER_DIR) or silent
# (accept connections and never answer). Started in this shell, detached from
# its stdout, so the pid is tracked for cleanup and no capture waits on it.
start_listener() {
  local mode=$1 portfile=$2 waited=0
  perl -MIO::Socket::INET -e '
    my ($mode, $dir, $portfile) = @ARGV;
    my $s = IO::Socket::INET->new(LocalAddr => "127.0.0.1", LocalPort => 0, Listen => 16, ReuseAddr => 1, Proto => "tcp") or die "listen: $!";
    open(my $pf, ">", "$portfile.tmp") or die; print $pf $s->sockport, "\n"; close $pf; rename "$portfile.tmp", $portfile;
    if ($mode eq "silent") { sleep 120; exit 0; }
    while (my $c = $s->accept) {
      my $line = <$c> // "";
      my ($method, $path) = split " ", $line;
      while (my $h = <$c>) { last if $h =~ /^\r?\n$/; }
      if (open(my $log, ">>", "$dir/requests")) { print $log ($method // ""), " ", ($path // ""), "\n"; close $log; }
      my $status = 200;
      if (open(my $sf, "<", "$dir/status")) { $status = <$sf>; chomp $status; close $sf; }
      my $body = "";
      if (open(my $bf, "<", "$dir/body")) { local $/; $body = <$bf> // ""; close $bf; }
      print $c "HTTP/1.1 $status X\r\nContent-Type: application/json\r\nContent-Length: " . length($body) . "\r\nConnection: close\r\n\r\n$body";
      close $c;
    }
  ' "$mode" "$SERVER_DIR" "$portfile" >/dev/null 2>&1 </dev/null &
  SERVER_PIDS+=("$!")
  while [ ! -s "$portfile" ]; do
    sleep 0.05
    waited=$((waited + 1))
    [ "$waited" -lt 200 ] || fail "the $mode listener did not start"
  done
}

start_listener serve "$TMP_ROOT/port"
start_listener silent "$TMP_ROOT/silent-port"
PORT=$(cat "$TMP_ROOT/port")
SILENT_PORT=$(cat "$TMP_ROOT/silent-port")
CLOSED_PORT=$(perl -MIO::Socket::INET -e '
  my $s = IO::Socket::INET->new(LocalAddr => "127.0.0.1", LocalPort => 0, Listen => 1, Proto => "tcp") or die;
  print $s->sockport, "\n"; close $s;')
BASE="http://127.0.0.1:$PORT/v1"

# serve <status> <body>: what the listener answers next.
serve() {
  printf '%s\n' "$1" > "$SERVER_DIR/status"
  printf '%s\n' "$2" > "$SERVER_DIR/body"
  : > "$SERVER_DIR/requests"
}

# models_json <provider>=<baseUrl>...: an agent models.json whose providers
# each declare the three Qwen ids at that base URL.
models_json() {
  local spec first=1
  {
    printf '{\n  // written like the captain'"'"'s file: comments and trailing commas\n  "providers": {\n'
    for spec in "$@"; do
      [ "$first" -eq 1 ] || printf ',\n'
      first=0
      printf '    "%s": { "baseUrl": "%s", "api": "openai-completions", "apiKey": "local",\n' "${spec%%=*}" "${spec#*=}"
      printf '      "models": [ { "id": "qwen-agent" }, { "id": "qwen-fast" }, { "id": "qwen-deep" }, ] }'
    done
    printf ',\n  },\n}\n'
  } > "$AGENT/models.json"
}

# llama-swap's own listing shape: aliases carry meta.llamaswap.modelID and every
# entry carries status.value. $1 is the real model loaded, or none.
llama_swap_list() {
  jq -cn --arg loaded "$1" '
    def entry($id; $model; $type): {id: $id, object: "model",
      status: {value: (if $model == $loaded then "loaded" else "unloaded" end)},
      meta: {llamaswap: (if $type == "alias" then {modelID: $model, type: "alias"} else {aliases: [], type: "model"} end)}};
    {data: [entry("qwen-agent"; "qwen-agent-3"; "alias"), entry("qwen-agent-3"; "qwen-agent-3"; "model"),
            entry("qwen-fast"; "qwen-fast-1"; "alias"), entry("qwen-fast-1"; "qwen-fast-1"; "model"),
            entry("qwen-deep"; "qwen-reason"; "alias"), entry("qwen-reason"; "qwen-reason"; "model")]}'
}

# llama-swap's default listing (includeAliasesInList off): only real models are
# rows, their aliases sit in meta.llamaswap.aliases, and a selector row reports
# loaded while any of its targets runs. $1 is the real model loaded, or none.
llama_swap_default_list() {
  jq -cn --arg loaded "$1" '
    def entry($id; $aliases): {id: $id, object: "model",
      status: {value: (if $id == $loaded then "loaded" else "unloaded" end)},
      meta: {llamaswap: {aliases: $aliases, type: "model"}}};
    {data: [entry("qwen-agent-3"; ["qwen-agent"]), entry("qwen-fast-1"; ["qwen-fast"]), entry("qwen-reason"; ["qwen-deep"]),
            {id: "qwen-any", object: "model", status: {value: (if $loaded == "none" then "unloaded" else "loaded" end)},
             meta: {llamaswap: {type: "selector"}}}]}'
}

# record <task> <harness> <model>: a task record of this home.
record() {
  printf 'harness=%s\nmodel=%s\nkind=ship\n' "$2" "$3" > "$LM_STATE/$1.meta"
}

run_check() {  # <args...> -> OUT, RC
  OUT=$("$TOOL" check --agent-dir "$AGENT" "$@" 2>&1)
  RC=$?
}

requests() { cat "$SERVER_DIR/requests" 2>/dev/null; }

models_json local-ai="$BASE"

# --- verdicts from the server's own load state ------------------------------

serve 200 "$(llama_swap_list qwen-reason)"
run_check pi:local-ai/qwen-deep
expect_code 0 "$RC" "an alias of the loaded model is ready: $OUT"
assert_contains "$OUT" "local-model: pi:local-ai/qwen-deep ready: qwen-deep is already loaded on $BASE, so no model switch is needed" \
  "the verdict should explain that the loaded alias needs no switch"
assert_contains "$OUT" "spare capacity is unconfirmed" "ready must never claim a free session"
assert_equals "GET /v1/models" "$(requests)" "the check must read only the model list, once"
pass "a llama-swap alias of the loaded model is ready without claiming spare capacity"

serve 200 "$(llama_swap_list qwen-reason)"
run_check pi:local-ai/qwen-agent pi:local-ai/qwen-fast
expect_code 1 "$RC" "a candidate needing a model switch is not launchable"
assert_contains "$OUT" "local-model: pi:local-ai/qwen-agent busy: qwen-reason (qwen-deep) is loaded on $BASE; starting qwen-agent would make the server switch models" \
  "the verdict should name the loaded model and its alias"
assert_contains "$OUT" "local-model: pi:local-ai/qwen-fast busy:" "every switching candidate is busy"
assert_equals "GET /v1/models" "$(requests)" "candidates on one server share a single request"
pass "a candidate that would switch the loaded model is busy, and one server is asked once"

serve 200 "$(llama_swap_list none)"
run_check pi:local-ai/qwen-agent
expect_code 0 "$RC" "nothing loaded means starting the model interrupts nothing"
assert_contains "$OUT" "ready: nothing is loaded on $BASE, so starting qwen-agent interrupts no session" "idle server is ready"
pass "an idle server is ready because loading a model interrupts no session"

serve 200 '{"data":[{"id":"qwen-agent","status":{"value":"loading"}},{"id":"qwen-fast","status":{"value":"unloaded"}}]}'
run_check pi:local-ai/qwen-agent pi:local-ai/qwen-fast
expect_code 1 "$RC" "a loading model is not launchable yet"
assert_contains "$OUT" "pi:local-ai/qwen-agent busy: qwen-agent is still loading" "the loading model waits"
assert_contains "$OUT" "pi:local-ai/qwen-fast busy: qwen-agent is loaded on $BASE" "another loading model counts as loaded"
pass "a model that is still loading holds both itself and every other model"

serve 200 "$(llama_swap_list qwen-reason)"
run_check pi:local-ai/qwen-coder
expect_code 1 "$RC" "a model the server does not offer is unavailable"
assert_contains "$OUT" "unavailable: $BASE is reachable but does not offer qwen-coder" "not offered is unavailable"
pass "a model the server does not offer is unavailable"

serve 200 '{"data":[{"id":"qwen-agent"}]}'
run_check pi:local-ai/qwen-agent
expect_code 0 "$RC" "the only model of a plain server is ready"
assert_contains "$OUT" "ready: qwen-agent is the only model $BASE offers" "sole model is ready"
serve 200 '{"data":[{"id":"qwen-agent"},{"id":"qwen-fast"}]}'
run_check pi:local-ai/qwen-agent
expect_code 1 "$RC" "several models without load state cannot rule out a switch"
assert_contains "$OUT" "unknown: $BASE offers 2 models without reporting which is loaded" "no load state is unknown"
serve 200 '{"data":[{"id":"qwen-agent","status":{"value":"unloaded"}},{"id":"qwen-fast","status":{"value":"sleeping"}}]}'
run_check pi:local-ai/qwen-agent
expect_code 1 "$RC" "an unrecognized load state cannot rule out a switch"
assert_contains "$OUT" "unknown: $BASE reports unrecognized load state sleeping for qwen-fast" "odd state is unknown"
pass "a server without trustworthy load state is unknown unless it offers a single model"

serve 401 '{"error":"unauthorized"}'
run_check pi:local-ai/qwen-agent
expect_code 1 "$RC" "a model list behind credentials is unknown"
assert_contains "$OUT" "unknown: $BASE needs credentials to list its models (HTTP 401)" "401 is unknown"
serve 500 'oops'
run_check pi:local-ai/qwen-agent
assert_contains "$OUT" "unknown: $BASE answered its model list with HTTP 500" "500 is unknown"
serve 200 'not json'
run_check pi:local-ai/qwen-agent
expect_code 1 "$RC" "a malformed model list is unknown"
assert_contains "$OUT" "unknown: $BASE did not answer with an OpenAI-compatible model list" "malformed is unknown"
pass "credential, error, and malformed answers are unknown, never ready"

# --- offline and silent servers ----------------------------------------------

models_json local-ai="http://127.0.0.1:$CLOSED_PORT/v1"
run_check pi:local-ai/qwen-agent
expect_code 1 "$RC" "an offline server is unavailable"
assert_contains "$OUT" "unavailable: the local model server http://127.0.0.1:$CLOSED_PORT/v1 is unreachable (no connection); start it and recheck" \
  "the offline verdict should say to start the server and recheck"
pass "an offline server is unavailable with a start-and-recheck hint"

models_json local-ai="http://127.0.0.1:$SILENT_PORT/v1"
started=$(date +%s)
run_check pi:local-ai/qwen-agent pi:local-ai/qwen-fast
elapsed=$(( $(date +%s) - started ))
expect_code 1 "$RC" "a silent server is unavailable"
assert_contains "$OUT" "unreachable (no answer within 1s)" "the silent verdict should name the bound"
[ "$elapsed" -le 4 ] || fail "two candidates on a silent server should cost one bounded probe, took ${elapsed}s"
pass "a silent server is unavailable within one bounded probe"

# --- what counts as local, and how Pi's configuration resolves -----------------

models_json local-ai="http://localhost:$PORT/v1"
serve 200 "$(llama_swap_list qwen-reason)"
run_check pi:local-ai/qwen-deep
expect_code 0 "$RC" "localhost is a local server"
assert_contains "$OUT" "pi:local-ai/qwen-deep ready:" "localhost is probed and ready"
for host in 172.32.0.1 100.128.0.1 8.8.8.8 api.example.com; do
  models_json cloud="https://$host/v1"
  serve 200 "$(llama_swap_list none)"
  run_check pi:cloud/qwen-agent
  expect_code 0 "$RC" "$host is not a local server"
  assert_contains "$OUT" "not-local: cloud/qwen-agent resolves to a provider without a local base URL" "$host is not local"
  assert_equals "" "$(requests)" "a cloud endpoint must never be probed ($host)"
done
for host in 10.255.255.1 172.16.0.1 192.168.254.254 169.254.1.1 100.64.0.1 '[fd00::1]' local-box gpu.lan; do
  models_json lab="http://$host:9/v1"
  run_check pi:lab/qwen-agent
  assert_not_contains "$OUT" "not-local" "$host must be treated as a local server"
done
pass "loopback, private, link-local, shared, and local names are local; public hosts are never probed"

models_json local-ai="http://127.0.0.1:$PORT/v1"
serve 200 "$(llama_swap_list qwen-reason)"
run_check claude:sonnet pi:openai-codex/gpt-5.6-luna codex
expect_code 0 "$RC" "other harnesses and cloud models are not gated"
assert_contains "$OUT" "claude:sonnet not-local: claude does not read Pi's model configuration" "claude is not local"
assert_contains "$OUT" "pi:openai-codex/gpt-5.6-luna not-local: openai-codex/gpt-5.6-luna names no locally served provider" "built-in provider is not local"
assert_equals "" "$(requests)" "no cloud candidate probes the local server"
run_check pi:qwen-deep
expect_code 0 "$RC" "a bare id resolves in the provider declaring it"
assert_contains "$OUT" "pi:qwen-deep ready:" "bare id resolves to the local provider"
run_check pi:local-ai/qwen-deep:high
assert_contains "$OUT" "pi:local-ai/qwen-deep:high ready:" "a thinking suffix still resolves the model"
pass "cloud models and other harnesses pass untouched; bare ids and thinking suffixes resolve"

printf '\xEF\xBB\xBF{"providers":{"one":{"baseUrl":"http://127.0.0.1:%s/v1","models":[{"id":"qwen-agent"}]},"two":{"baseUrl":"http://127.0.0.1:%s/v1","models":[{"id":"qwen-agent","baseUrl":"http://127.0.0.1:%s/v1"}]}}}\n' \
  "$PORT" "$CLOSED_PORT" "$PORT" > "$AGENT/models.json"
run_check pi:two/qwen-agent
assert_contains "$OUT" "pi:two/qwen-agent busy: qwen-reason (qwen-deep) is loaded on http://127.0.0.1:$PORT/v1" \
  "a model's own baseUrl wins over its provider's, and a BOM is accepted"
run_check pi:qwen-agent
expect_code 1 "$RC" "a bare id in two local providers is ambiguous"
assert_contains "$OUT" "unknown: qwen-agent matches more than one local provider" "ambiguity is unknown"
pass "model-level base URLs win and an ambiguous bare id is unknown"

models_json local-ai="$BASE"
printf '{ "defaultProvider": "local-ai", "defaultModel": "qwen-agent" }\n' > "$AGENT/settings.json"
run_check pi
expect_code 1 "$RC" "Pi's local default model is gated like a named one"
assert_contains "$OUT" "local-model: pi busy: local-ai/qwen-agent (Pi's default model): qwen-reason (qwen-deep) is loaded" \
  "a launch without a model resolves Pi's default"
printf '{}\n' > "$AGENT/settings.json"
run_check pi
expect_code 1 "$RC" "no model and no default with a local provider configured is unknown"
assert_contains "$OUT" "unknown: no model is named and $AGENT/settings.json sets no default" "unset default is unknown"
printf '{ "defaultProvider": "local-ai", "defaultModel": "qwen-agent", }\n' > "$AGENT/settings.json"
run_check pi
assert_contains "$OUT" "unknown: no model is named and $AGENT/settings.json sets no default" \
  "a settings file Pi's strict parser rejects names no default"
rm -f "$AGENT/settings.json" "$AGENT/models.json"
run_check pi pi:local-ai/qwen-agent
expect_code 0 "$RC" "without models.json nothing is local"
assert_contains "$OUT" "local-model: pi not-local: no model is named and no local provider is configured" "no config is not local"
pass "a launch without a model resolves Pi's default, and no models.json means not local"

mkdir -p "$TMP_ROOT/user/.pi/agent"
printf '{"providers":{"local-ai":{"baseUrl":"%s","models":[{"id":"qwen-deep"}]}}}\n' "$BASE" > "$TMP_ROOT/user/.pi/agent/models.json"
# shellcheck disable=SC2088  # The literal ~ is what Pi and the check expand.
OUT=$(env -u FM_PI_AGENT_DIR_OVERRIDE HOME="$TMP_ROOT/user" PI_CODING_AGENT_DIR='~/.pi/agent' "$TOOL" check pi:local-ai/qwen-deep 2>&1)
assert_contains "$OUT" "pi:local-ai/qwen-deep ready:" "PI_CODING_AGENT_DIR with a leading ~ is expanded"
OUT=$(env -u FM_PI_AGENT_DIR_OVERRIDE HOME="$TMP_ROOT/user" "$TOOL" check pi:local-ai/qwen-deep 2>&1)
assert_contains "$OUT" "pi:local-ai/qwen-deep ready:" "the default agent directory is ~/.pi/agent"
pass "the agent directory follows PI_CODING_AGENT_DIR and Pi's default"

printf '{"providers": {' > "$AGENT/models.json"
run_check pi:local-ai/qwen-agent pi:openai-codex/gpt-5.6-luna
expect_code 0 "$RC" "an unreadable models.json must not block cloud launches"
assert_contains "$OUT" "pi:local-ai/qwen-agent unchecked: Pi's $AGENT/models.json is not a valid models configuration" \
  "the unreadable configuration is disclosed"
printf '{"rules":[],"default":[{"harness":"pi","model":"local-ai/qwen-deep"}]}\n' > "$TMP_ROOT/rules-default.json"
OUT=$("$TOOL" observe --agent-dir "$AGENT" --rules "$TMP_ROOT/rules-default.json")
assert_contains "$OUT" "local models: Pi's $AGENT/models.json is not a valid models configuration, so no local dispatch candidate can be vouched for" \
  "the observation discloses that no local candidate is vouched for"
pass "an unreadable models.json is unchecked: disclosed, never blocking"

# --- llama-swap's default listing and selector rows ----------------------------

models_json local-ai="$BASE"
serve 200 "$(llama_swap_default_list qwen-agent-3)"
run_check pi:local-ai/qwen-agent
expect_code 0 "$RC" "an alias listed only under its model's meta is found: $OUT"
assert_contains "$OUT" "pi:local-ai/qwen-agent ready: qwen-agent is already loaded on $BASE" \
  "the alias takes its real model's load state"
run_check pi:local-ai/qwen-fast
expect_code 1 "$RC" "another model is loaded"
assert_contains "$OUT" "pi:local-ai/qwen-fast busy: qwen-agent-3 (qwen-agent) is loaded on $BASE" \
  "the loaded model is named with its aliases and the selector row is not a second loaded model"
serve 200 "$(llama_swap_default_list none)"
run_check pi:local-ai/qwen-deep
expect_code 0 "$RC" "nothing loaded: $OUT"
assert_contains "$OUT" "ready: nothing is loaded on $BASE" "an idle selector row is not a loaded model"
pass "llama-swap aliases are found in the default listing and selector rows never count as loaded"

# --- declared session limits ---------------------------------------------------

printf '{"localSessions":{"local-ai/qwen-agent":3,"local-ai/qwen-fast":1,"local-ai/qwen-deep":1}}\n' > "$LM_CONFIG/crew-dispatch.json"
printf '{ "defaultProvider": "local-ai", "defaultModel": "qwen-agent" }\n' > "$AGENT/settings.json"
serve 200 "$(llama_swap_default_list qwen-agent-3)"
record a1 pi local-ai/qwen-agent
record a2 pi-signed qwen-agent
record c1 claude sonnet
record c2 pi openai-codex/gpt-5.6-luna
run_check pi:local-ai/qwen-agent
expect_code 0 "$RC" "two of three sessions leave room: $OUT"
assert_contains "$OUT" "pi:local-ai/qwen-agent ready:" "qwen-agent with two sessions is ready"
record a3 pi default
run_check pi:local-ai/qwen-agent pi:openai-codex/gpt-5.6-luna
expect_code 1 "$RC" "three of three sessions are full"
assert_contains "$OUT" "pi:local-ai/qwen-agent full: 3 of 3 sessions for local-ai/qwen-agent are in use by task(s) a1, a2, a3" \
  "the full verdict names the count, the limit, and the occupying tasks; a bare id and Pi's default count alike"
assert_contains "$OUT" "pi:openai-codex/gpt-5.6-luna not-local:" "a cloud candidate is unaffected by local sessions"
run_check --task a3 pi:local-ai/qwen-agent
expect_code 0 "$RC" "a relaunch of an occupying task excludes itself: $OUT"
rm -f "$LM_STATE"/a*.meta
pass "qwen-agent takes three sessions, counted from this home's Pi task records only"

serve 200 "$(llama_swap_default_list qwen-fast-1)"
record f1 pi local-ai/qwen-fast
run_check pi:qwen-fast
expect_code 1 "$RC" "one qwen-fast session is full"
assert_contains "$OUT" "pi:qwen-fast full: 1 of 1 sessions for local-ai/qwen-fast are in use by task(s) f1" "qwen-fast takes one session"
serve 200 "$(llama_swap_default_list none)"
run_check pi:local-ai/qwen-deep
expect_code 1 "$RC" "a session on another model of the server blocks a switch even while nothing is loaded"
assert_contains "$OUT" "pi:local-ai/qwen-deep busy: task(s) f1 (qwen-fast-1) use another model of $BASE; starting qwen-deep would make the server switch models under them" \
  "the busy verdict names the task holding the other model"
pass "qwen-fast takes one session, and a record on another local model holds the server"

serve 200 "$(llama_swap_default_list qwen-fast-1)"
run_check pi:local-ai/qwen-agent
expect_code 1 "$RC" "a new launch never switches away from a loaded model"
run_check --task f1 pi:local-ai/qwen-agent
expect_code 0 "$RC" "a relaunch of the sole session may switch away from its own loaded model: $OUT"
assert_contains "$OUT" "pi:local-ai/qwen-agent ready: qwen-fast-1 (qwen-fast) is loaded on $BASE only for the session of task f1, which this relaunch replaces" \
  "the ready verdict says the relaunch replaces its own session"
record f2 pi local-ai/qwen-fast
run_check --task f1 pi:local-ai/qwen-agent
expect_code 1 "$RC" "another task on the loaded model keeps the relaunch from switching it"
assert_contains "$OUT" "pi:local-ai/qwen-agent busy: task(s) f2 (qwen-fast-1) use another model of $BASE" \
  "the busy verdict names the other task on the loaded model"
rm -f "$LM_STATE/f2.meta"
pass "a relaunch may switch away only from a loaded model its own record alone uses"

rm -f "$LM_STATE/f1.meta"
printf 'harness=pi\nmodel=local-ai/qwen-fast\nkind=secondmate\nremote_host=gpu-box\n' > "$LM_STATE/r1.meta"
run_check pi:local-ai/qwen-fast
expect_code 0 "$RC" "a remote secondmate record never takes a session on this host's server: $OUT"
assert_contains "$OUT" "pi:local-ai/qwen-fast ready:" "qwen-fast stays ready beside a remote record"
serve 200 "$(llama_swap_default_list none)"
run_check pi:local-ai/qwen-deep
expect_code 0 "$RC" "a remote secondmate record never holds this host's server on another model: $OUT"
rm -f "$LM_STATE/r1.meta"
record f1 pi local-ai/qwen-fast
pass "remote secondmate records never count against this host's local server"

rm -f "$LM_CONFIG/crew-dispatch.json"
serve 200 "$(llama_swap_default_list qwen-fast-1)"
run_check pi:local-ai/qwen-fast
expect_code 0 "$RC" "a model without a declared limit keeps today's behavior: $OUT"
assert_contains "$OUT" "pi:local-ai/qwen-fast ready: qwen-fast is already loaded" "no limit means ready"
printf '{"localSessions":{"local-ai/qwen-fast":0}}\n' > "$LM_CONFIG/crew-dispatch.json"
run_check pi:local-ai/qwen-fast pi:openai-codex/gpt-5.6-luna
expect_code 1 "$RC" "a malformed declaration cannot vouch for a local candidate"
assert_contains "$OUT" "pi:local-ai/qwen-fast unknown: $LM_CONFIG/crew-dispatch.json does not declare localSessions" "a malformed declaration is unknown"
assert_contains "$OUT" "pi:openai-codex/gpt-5.6-luna not-local:" "a malformed declaration never gates a cloud candidate"
printf '{"default":{"harness":"pi","model":"local-ai/qwen-fast"}}\n' > "$TMP_ROOT/rules-fast.json"
: > "$SERVER_DIR/requests"
OUT=$("$TOOL" observe --agent-dir "$AGENT" --rules "$TMP_ROOT/rules-fast.json" 2>&1); RC=$?
expect_code 0 "$RC" "observe stays informational with malformed limits"
assert_equals "local models: the localSessions session limits in $LM_CONFIG/crew-dispatch.json are malformed, so no local dispatch candidate can be vouched for; every local handoff is rechecked first" \
  "$OUT" "malformed limits are observed as one line, with no false unreachable server"
assert_equals "" "$(requests)" "malformed limits observe no server"
rm -f "$LM_CONFIG/crew-dispatch.json" "$LM_STATE"/*.meta "$AGENT/settings.json"
pass "no declared limit keeps the switch-only gate, and a malformed one makes local candidates unknown"

# --- the startup observation -------------------------------------------------

cat > "$TMP_ROOT/rules.json" <<'JSON'
{
  "rules": [
    { "when": "A simple fix.", "use": [
      { "harness": "pi", "model": "openai-codex/gpt-5.6-luna", "provider": "codex" },
      { "harness": "claude", "model": "sonnet" },
      { "harness": "pi", "model": "local-ai/qwen-agent", "provider": "local-ai" },
      { "harness": "pi", "model": "local-ai/qwen-fast", "provider": "local-ai" } ] }
  ],
  "default": [ { "harness": "claude", "model": "opus" }, { "harness": "pi", "model": "local-ai/qwen-deep" } ]
}
JSON
models_json local-ai="$BASE"
serve 200 "$(llama_swap_list qwen-reason)"
OUT=$("$TOOL" observe --agent-dir "$AGENT" --rules "$TMP_ROOT/rules.json"); RC=$?
expect_code 0 "$RC" "observe is informational"
assert_equals "local models: $BASE is reachable; loaded: qwen-reason (qwen-deep); ready now: qwen-deep; not now: qwen-agent (would switch the loaded model), qwen-fast (would switch the loaded model); every local handoff is rechecked first" \
  "$OUT" "one reachable server yields one line naming what is ready and what is held"
assert_equals "GET /v1/models" "$(requests)" "observe asks each server once"
models_json local-ai="http://127.0.0.1:$CLOSED_PORT/v1"
OUT=$("$TOOL" observe --agent-dir "$AGENT" --rules "$TMP_ROOT/rules.json")
assert_equals "local models: http://127.0.0.1:$CLOSED_PORT/v1 is unreachable (no connection); local candidates qwen-agent, qwen-deep, qwen-fast cannot take work until it is started; cloud profiles still apply, and every local handoff is rechecked first" \
  "$OUT" "an offline server yields one line saying the cloud profiles still apply"
printf '{"rules":[{"when":"x","use":{"harness":"pi","model":"openai-codex/gpt-5.6-luna"}}]}\n' > "$TMP_ROOT/rules-cloud.json"
OUT=$("$TOOL" observe --agent-dir "$AGENT" --rules "$TMP_ROOT/rules-cloud.json")
assert_equals "" "$OUT" "no local profile means no observation"
OUT=$("$TOOL" observe --agent-dir "$AGENT" --rules "$TMP_ROOT/absent.json"); RC=$?
expect_code 0 "$RC" "an absent rules file is fine"
assert_equals "" "$OUT" "an absent rules file observes nothing"
pass "the startup observation reports each local server once and stays silent without local profiles"

OUT=$("$TOOL" check 2>&1); RC=$?
expect_code 2 "$RC" "check needs a candidate"
OUT=$("$TOOL" check 'bad harness:x' 2>&1); RC=$?
expect_code 2 "$RC" "a malformed harness is a usage error"
pass "usage errors exit 2"

# --- the fm-spawn launch gate -------------------------------------------------

# spawn_case <name> -> CASE HOME_DIR PROJ WT FAKEBIN
spawn_case() {
  CASE="$TMP_ROOT/spawn-$1"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/project"
  WT="$CASE/wt"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake" pi)
  fm_test_spawn_home "$HOME_DIR" pi
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
  : > "$CASE/launch.log"
}

spawn_pi() {  # <id> [fm-spawn args...] -> OUT RC
  local id=$1
  shift
  fm_test_spawn_brief "$HOME_DIR" "$id"
  OUT=$(FM_PI_AGENT_DIR_OVERRIDE="$AGENT" FM_FAKE_LAUNCH_LOG="$CASE/launch.log" \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" --mode no-mistakes --yolo off --harness pi "$@")
  RC=$?
}

assert_not_launched() {  # <id>
  assert_absent "$HOME_DIR/state/$1.meta" "a refused spawn must not publish a task record"
  [ ! -s "$CASE/launch.log" ] || fail "a refused spawn must not launch a worker: $(cat "$CASE/launch.log")"
}

models_json local-ai="$BASE"
serve 200 "$(llama_swap_list qwen-reason)"
spawn_case busy
spawn_pi lm-busy --model local-ai/qwen-agent
expect_code 1 "$RC" "a spawn that would switch the loaded model must refuse: $OUT"
assert_contains "$OUT" "refusing to launch lm-busy on a local model that cannot take it now: pi:local-ai/qwen-agent busy: qwen-reason (qwen-deep) is loaded" \
  "the refusal carries the check's reason"
assert_not_launched lm-busy
pass "fm-spawn refuses a Pi launch that would switch the loaded local model before anything exists"

models_json local-ai="http://127.0.0.1:$CLOSED_PORT/v1"
spawn_case offline
spawn_pi lm-offline --model local-ai/qwen-agent
expect_code 1 "$RC" "a spawn against an offline local server must refuse"
assert_contains "$OUT" "is unreachable (no connection); start it and recheck" "the refusal says to start the server"
assert_not_launched lm-offline
spawn_pi lm-offline-cloud --model openai-codex/gpt-5.6-luna
expect_code 0 "$RC" "a cloud Pi model launches while the local server is offline: $OUT"
assert_present "$HOME_DIR/state/lm-offline-cloud.meta" "the cloud launch publishes its task record"
pass "an offline local server refuses local launches before any session exists while cloud Pi launches proceed"

models_json local-ai="$BASE"
serve 200 "$(llama_swap_list qwen-fast-1)"
spawn_case full
printf '{"localSessions":{"local-ai/qwen-fast":1}}\n' > "$HOME_DIR/config/crew-dispatch.json"
printf 'harness=pi\nmodel=local-ai/qwen-fast\nkind=ship\n' > "$HOME_DIR/state/lm-held.meta"
spawn_pi lm-full --model local-ai/qwen-fast
expect_code 1 "$RC" "a spawn on a full local model must refuse: $OUT"
assert_contains "$OUT" "refusing to launch lm-full on a local model that cannot take it now: pi:local-ai/qwen-fast full: 1 of 1 sessions for local-ai/qwen-fast are in use by task(s) lm-held" \
  "the refusal carries the session count"
assert_not_launched lm-full
pass "fm-spawn refuses a Pi launch on a local model whose session limit is reached before anything exists"

serve 200 "$(llama_swap_list qwen-reason)"
spawn_case ready
spawn_pi lm-ready --model local-ai/qwen-deep
expect_code 0 "$RC" "a ready local model launches: $OUT"
assert_present "$HOME_DIR/state/lm-ready.meta" "the ready launch publishes its task record"
printf '{"providers": {' > "$AGENT/models.json"
spawn_pi lm-unchecked --model openai-codex/gpt-5.6-luna
expect_code 0 "$RC" "an unreadable models.json never blocks a cloud launch: $OUT"
assert_contains "$OUT" "warning: pi:openai-codex/gpt-5.6-luna unchecked:" "the unreadable configuration is disclosed at launch"
pass "ready local models launch, and an unreadable Pi configuration only warns"

printf '# all fm-local-model tests passed\n'
