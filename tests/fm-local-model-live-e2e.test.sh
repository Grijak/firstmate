#!/usr/bin/env bash
# Default-on live guard for bin/fm-local-model.sh against every installed Pi
# runner: the check must resolve a Pi launch to the same server and model id
# the real Pi then requests.
#
# The check reads Pi's own configuration - where the agent directory is, how
# models.json tolerates comments and trailing commas, that a model's baseUrl
# wins over its provider's, and that settings.json names the default model -
# so a fake can only restate those assumptions. This guard writes a throwaway
# agent directory whose provider baseUrl points at a closed port while one
# model's own baseUrl points at a local listener that speaks just enough of
# the OpenAI-compatible API. It asks the check about that model and about a
# launch with no model, then runs the real Pi in print mode for both and
# asserts the listener received the chat request for exactly the model id the
# check probed. The listener is a stand-in, so no real model runs and no
# tokens are spent; the shared live gate therefore runs it by default wherever
# Pi is installed. Run it after every Pi upgrade and before trusting the
# "Local model check reads Pi's configuration" entry in
# docs/verification/runtime-backends.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_LOCAL_MODEL_LIVE_E2E jq perl curl
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

TOOL="$ROOT/bin/fm-local-model.sh"
TMP_ROOT=$(fm_test_tmproot fm-local-model-live)
export HOME="$TMP_ROOT/home"
mkdir -p "$HOME"
unset PI_CODING_AGENT_DIR FM_PI_AGENT_DIR_OVERRIDE
LOG="$TMP_ROOT/requests"
SERVER_PID=
CHECKED=
trap '[ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null; fm_test_cleanup' EXIT

# The listener logs "<method> <path> <model>" per request, answers the model
# list with m-live loaded, and streams one short completion for a chat request.
perl -MIO::Socket::INET -e '
  my ($log, $portfile) = @ARGV;
  my $s = IO::Socket::INET->new(LocalAddr => "127.0.0.1", LocalPort => 0, Listen => 16, ReuseAddr => 1, Proto => "tcp") or die;
  open(my $pf, ">", "$portfile.tmp") or die; print $pf $s->sockport, "\n"; close $pf; rename "$portfile.tmp", $portfile;
  while (my $c = $s->accept) {
    my $line = <$c> // ""; my ($method, $path) = split " ", $line; my $len = 0;
    while (my $h = <$c>) { last if $h =~ /^\r?\n$/; $len = $1 if $h =~ /^content-length:\s*(\d+)/i; }
    my $body = ""; read($c, $body, $len) if $len;
    my ($model) = $body =~ /"model"\s*:\s*"([^"]*)"/;
    if (open(my $l, ">>", $log)) { print $l ($method // ""), " ", ($path // ""), " ", ($model // "-"), "\n"; close $l; }
    if (($path // "") =~ m{/models$}) {
      my $j = q({"data":[{"id":"m-live","status":{"value":"loaded"}},{"id":"m-default","status":{"value":"unloaded"}}]});
      print $c "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " . length($j) . "\r\nConnection: close\r\n\r\n$j";
    } elsif (($path // "") =~ m{/chat/completions$}) {
      my $m = $model // "m";
      print $c "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n";
      print $c qq(data: {"id":"c1","object":"chat.completion.chunk","model":"$m","choices":[{"index":0,"delta":{"role":"assistant","content":"pong"},"finish_reason":null}]}\n\n);
      print $c qq(data: {"id":"c1","object":"chat.completion.chunk","model":"$m","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n);
      print $c "data: [DONE]\n\n";
    } else {
      print $c "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    }
    close $c;
  }
' "$LOG" "$TMP_ROOT/port" >/dev/null 2>&1 </dev/null &
SERVER_PID=$!
waited=0
while [ ! -s "$TMP_ROOT/port" ]; do
  sleep 0.05
  waited=$((waited + 1))
  [ "$waited" -lt 200 ] || fail "the stand-in model server did not start"
done
PORT=$(cat "$TMP_ROOT/port")
CLOSED=$(perl -MIO::Socket::INET -e '
  my $s = IO::Socket::INET->new(LocalAddr => "127.0.0.1", LocalPort => 0, Listen => 1, Proto => "tcp") or die;
  print $s->sockport, "\n"; close $s;')

# pi_print <exe> <agent-dir> [--model <m>]: one print-mode turn, bounded.
pi_print() {
  local exe=$1 agent=$2
  shift 2
  fm_run_timed 90 env -i HOME="$HOME" PATH="$PATH" TERM=dumb PI_CODING_AGENT_DIR="$agent" PI_OFFLINE=1 \
    "$exe" -p --no-session --no-context-files --no-extensions --no-skills --no-prompt-templates "$@" ping \
    </dev/null 2>&1
}

pi_live_cases() {
  local exe=$1 version agent out
  version=$("$exe" --version 2>/dev/null | head -1)
  agent="$TMP_ROOT/$exe-agent"
  mkdir -p "$agent"
  printf '\xEF\xBB\xBF{\n  // the provider default points nowhere; one model overrides it\n  "providers": {\n    "fm-live": { "baseUrl": "http://127.0.0.1:%s/v1", "api": "openai-completions", "apiKey": "local",\n      "models": [ { "id": "m-live", "baseUrl": "http://127.0.0.1:%s/v1" }, { "id": "m-default", "baseUrl": "http://127.0.0.1:%s/v1" }, ] },\n  },\n}\n' \
    "$CLOSED" "$PORT" "$PORT" > "$agent/models.json"
  printf '{ "defaultProvider": "fm-live", "defaultModel": "m-default" }\n' > "$agent/settings.json"

  : > "$LOG"
  out=$("$TOOL" check --agent-dir "$agent" "$exe:fm-live/m-live" 2>&1) ||
    fail "$exe $version: the check did not find the loaded model ready: $out"
  assert_contains "$out" "ready: m-live is already loaded on http://127.0.0.1:$PORT/v1" \
    "$exe $version: the check must probe the model's own baseUrl, not its provider's"
  out=$(pi_print "$exe" "$agent" --model fm-live/m-live) ||
    fail "$exe $version: print mode against the stand-in server failed: $out"
  grep -qx "POST /v1/chat/completions m-live" "$LOG" ||
    fail "$exe $version: Pi did not request m-live from the server the check probed: $(cat "$LOG")"

  : > "$LOG"
  out=$("$TOOL" check --agent-dir "$agent" "$exe" 2>&1)
  assert_contains "$out" "fm-live/m-default (Pi's default model): m-live is loaded on http://127.0.0.1:$PORT/v1; starting m-default would make the server switch models" \
    "$exe $version: the check must resolve a launch without a model to Pi's settings default"
  out=$(pi_print "$exe" "$agent") ||
    fail "$exe $version: print mode with Pi's default model failed: $out"
  grep -qx "POST /v1/chat/completions m-default" "$LOG" ||
    fail "$exe $version: Pi's default model is not the one the check resolved: $(cat "$LOG")"

  # Pi reads settings.json as strict JSON: with a trailing comma it names no
  # default and Pi picks some other model, so the check must not claim one.
  printf '{ "defaultProvider": "fm-live", "defaultModel": "m-default", }\n' > "$agent/settings.json"
  : > "$LOG"
  out=$(pi_print "$exe" "$agent") || fail "$exe $version: print mode with a lenient settings file failed: $out"
  grep -q "^POST /v1/chat/completions m-default$" "$LOG" &&
    fail "$exe $version: Pi now honors a settings.json with a trailing comma; loosen the check's settings parser to match"
  out=$("$TOOL" check --agent-dir "$agent" "$exe" 2>&1)
  assert_contains "$out" "unknown: no model is named and $agent/settings.json sets no default" \
    "$exe $version: the check must not resolve a default Pi itself ignores"
  pass "$exe $version: the check resolves the same server and model id Pi requests, for a named model and for Pi's default, and parses settings as strictly as Pi"
  CHECKED="$CHECKED $exe"
}

for runner in pi pi-signed; do
  if ! command -v "$runner" >/dev/null 2>&1; then
    printf 'skip-runner: %s is not installed, so its configuration was not exercised\n' "$runner"
    continue
  fi
  pi_live_cases "$runner"
done

if [ -z "$CHECKED" ]; then
  if [ "${FM_LOCAL_MODEL_LIVE_E2E:-${FM_LIVE:-}}" = 1 ]; then
    fail "the local model live guard was requested but neither pi nor pi-signed is installed"
  fi
  echo "skip: live: neither pi nor pi-signed is installed"
  exit 0
fi
echo "# local model live guard checked:$CHECKED"
