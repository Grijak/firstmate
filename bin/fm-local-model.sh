#!/usr/bin/env bash
# fm-local-model.sh - read-only availability check for Pi worker launches whose
# model is served by a local model server, such as llama.cpp behind llama-swap.
#
# Usage:
#   fm-local-model.sh check [--agent-dir <dir>] [--task <id>] <harness>[:<model>]...
#   fm-local-model.sh observe [--agent-dir <dir>] [--rules <crew-dispatch.json>]
#
# check    Answers, right now, whether each candidate may be launched without
#          disturbing a local model server. One line per candidate on stdout:
#            local-model: <harness>[:<model>] <verdict>: <detail>
#          Exit 0 when no candidate is known to be unsafe (ready, not-local, or
#          unchecked), 1 when any is unavailable, busy, full, or unknown, and 2
#          for a usage error. --task names the task being launched or
#          relaunched, so its own record never counts against it, and a
#          loaded model that only its own record uses may be switched away
#          from, because the relaunch replaces that session.
#          Every dispatch decision and every Pi launch reruns it; an earlier
#          result, including the startup observation, never authorizes a launch.
# observe  The startup observation for docs/configuration.md "Local model
#          availability": the Pi profiles in config/crew-dispatch.json (or
#          --rules) are resolved and each local server they name is probed once.
#          Prints one line per local server, or nothing when no Pi profile names
#          a local server or the rules file is absent or unreadable. Always
#          exits 0: it is informational and never gates anything.
#
# Verdicts:
#   ready        the server is reachable, offers the model, and starting it
#                needs no model switch: the model is already loaded, nothing at
#                all is loaded, only a model the --task record alone uses is
#                loaded, or it is the only model the server offers;
#                no task record of this home holds another model of the same
#                server; and a declared session limit is not yet reached.
#                The server never reports free session slots, so ready never
#                proves spare capacity beyond this home's own records.
#   unavailable  the server does not answer, or answers without offering the
#                model. Launching would leave the worker unable to start.
#   busy         another model is loaded or loading, so starting this one would
#                make a llama-swap style server switch models and interrupt the
#                sessions using the loaded one; or this model is still loading;
#                or a task record of this home uses another model of the same
#                server, even while nothing is loaded.
#   full         the model's declared session limit is reached by this home's
#                task records; the detail names the in-use count, the limit,
#                and the occupying task ids.
#   unknown      the server answered but its load state cannot rule out a
#                switch, it needs credentials to list models, or Pi could pick a
#                local model that cannot be determined from its configuration,
#                or the session limits in config/crew-dispatch.json are
#                malformed.
#   unchecked    Pi's models.json exists but cannot be read or parsed, so
#                whether the model is local cannot be established. Pi itself
#                loads no custom provider from such a file, so no local server
#                can be reached through it and cloud launches stay unblocked;
#                the verdict is a warning that no local candidate is vouched for.
#   not-local    no local model server is involved: not a Pi-family harness, or
#                the model resolves to a provider without a local base URL.
#
# Effective configuration, read the way Pi reads it and never duplicated:
#   The agent directory is --agent-dir, else FM_PI_AGENT_DIR_OVERRIDE (an
#   alternate directory, mainly for tests), else PI_CODING_AGENT_DIR (with a
#   leading ~ expanded), else $HOME/.pi/agent. Its models.json declares
#   custom providers; a UTF-8 BOM, // comments, and trailing commas are
#   stripped with Pi's own rules before parsing. A model's own baseUrl wins
#   over its provider's. A --model <provider>/<id> resolves in that provider;
#   a bare id resolves in every provider declaring it, and more than one local
#   match is unknown. With no model, Pi's defaultProvider and defaultModel in
#   the agent directory's settings.json decide; Pi parses that file as strict
#   JSON, so a file with comments or trailing commas names no default, and
#   with a local provider configured the launch is unknown. Pi has no built-in local
#   provider, so an absent models.json means not-local.
#   A base URL is local when its host is localhost or *.localhost, a loopback,
#   RFC 1918 private, link-local, or 100.64.0.0/10 shared IPv4 address, IPv6
#   ::1, fc00::/7, or fe80::/10, a single-label host name, or a name ending in
#   .local, .lan, .internal, or .home.arpa. Any other host is treated as a
#   cloud endpoint and gets no local gate.
#
# Probe: one GET <baseUrl>/models per distinct server, sent without
#   credentials and without a proxy, bounded by FM_LOCAL_MODEL_TIMEOUT seconds
#   (default 3) for connection and whole request. It never requests a
#   completion or touches a llama-swap upstream, load, or unload endpoint, so
#   it can neither load nor unload a model. Load state comes from each entry's
#   status.value (loaded, loading, unloaded), which llama-swap and llama.cpp's
#   router publish. A model id matches an entry's id, its
#   meta.llamaswap.modelID, or any of its meta.llamaswap.aliases, so a
#   llama-swap alias resolves to its real model whether or not the server
#   lists aliases as their own rows; llama-swap selector and peer entries
#   never count as a loaded local model.
#
# Session limits: the optional localSessions object in the effective home's
#   config/crew-dispatch.json (docs/configuration.md "Crew dispatch profiles"
#   owns the field) maps a Pi model identity <provider>/<id> to its maximum
#   concurrent sessions. Every state/*.meta task record of this home whose
#   harness is pi or pi-signed, that names no remote_host, and whose model
#   resolves, through the same resolution as a candidate, to a model of the
#   same server counts as one session on that server's model, whether or not
#   its pane is still alive.
#   A model with no declared limit is only gated on switching.
#
# Known limits: the server cannot tell how many sessions use a loaded model,
#   so ready never proves a free slot; extension-registered providers, project
#   .pi/settings.json overrides, and raw launch commands are not inspected; the
#   check reads the invoking process's agent directory, while an unpinned
#   worker pane may carry a different PI_CODING_AGENT_DIR, and task records
#   resolve through that same directory; only this home's task records are
#   counted, so sessions of other homes, such as a secondmate's own workers,
#   are not; a remote secondmate's record names a remote_host and runs against
#   that host's own server, so it never counts here; and concurrent spawns are
#   not serialized against each other.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
}

TIMEOUT=${FM_LOCAL_MODEL_TIMEOUT:-3}
case "$TIMEOUT" in '' | *[!0-9]* | 0) TIMEOUT=3 ;; esac

AGENT_DIR=
MODELS_JSON='{"providers":{}}'
SETTINGS_JSON='{}'
CONFIG_STATE=absent
CONFIG_DETAIL=
LIMITS_JSON='{}'
LIMITS_STATE=ok
TASK=
WORK=

# strip_pi_json <file>: Pi's stripBom plus stripJsonComments for models.json,
# byte for byte in intent: drop a leading BOM, then // comments outside
# strings, then commas directly before a closing brace or bracket outside
# strings.
strip_pi_json() {
  perl -0777 -pe '
    s/\A\xEF\xBB\xBF//;
    s/("(?:\\.|[^"\\])*")|\/\/[^\n]*/defined $1 ? $1 : ""/ge;
    s/("(?:\\.|[^"\\])*")|,(\s*[}\]])/defined $1 ? $1 : $2/ge;
  ' "$1"
}

# strip_bom <file>: Pi reads settings.json with stripBom and a strict
# JSON.parse, so a file it would reject must not name a default here either.
strip_bom() {
  perl -0777 -pe 's/\A\xEF\xBB\xBF//' "$1"
}

resolve_agent_dir() {
  local dir=${1:-${FM_PI_AGENT_DIR_OVERRIDE:-${PI_CODING_AGENT_DIR:-}}}
  if [ -z "$dir" ]; then
    dir="${HOME:-}/.pi/agent"
  fi
  # shellcheck disable=SC2088  # Pi expands a literal leading ~ itself.
  case "$dir" in
  '~') dir=${HOME:-} ;;
  '~/'*) dir="${HOME:-}/${dir#'~/'}" ;;
  esac
  AGENT_DIR=$dir
}

load_config() {
  local file="$AGENT_DIR/models.json" settings="$AGENT_DIR/settings.json" stripped parsed
  if [ -e "$file" ] || [ -L "$file" ]; then
    if [ ! -f "$file" ] || [ ! -r "$file" ]; then
      CONFIG_STATE=invalid
      CONFIG_DETAIL="Pi's $file cannot be read"
    elif ! stripped=$(strip_pi_json "$file" 2>/dev/null) ||
      ! parsed=$(printf '%s' "$stripped" | jq -ce '
          if type == "object" and (.providers | type) == "object" then . else error("shape") end
        ' 2>/dev/null); then
      CONFIG_STATE=invalid
      CONFIG_DETAIL="Pi's $file is not a valid models configuration"
    else
      CONFIG_STATE=ok
      MODELS_JSON=$parsed
    fi
  fi
  if [ -f "$settings" ] && [ -r "$settings" ] &&
    stripped=$(strip_bom "$settings" 2>/dev/null) &&
    parsed=$(printf '%s' "$stripped" | jq -ce 'if type == "object" then . else error("shape") end' 2>/dev/null); then
    SETTINGS_JSON=$parsed
  fi
}

# load_limits: the localSessions declaration of this home's
# config/crew-dispatch.json; an absent file or field declares no limit.
load_limits() {
  local file="$CONFIG/crew-dispatch.json"
  [ -e "$file" ] || [ -L "$file" ] || return 0
  LIMITS_JSON=$(jq -ce '
    (if has("localSessions") then .localSessions else {} end) as $s
    | if ($s | type) == "object" and all($s | to_entries[];
          (.key | test("^[^/]+/.+$")) and (.value | type) == "number" and .value >= 1 and .value == (.value | floor))
      then $s else error("shape") end' "$file" 2>/dev/null) || {
    LIMITS_JSON='{}'
    LIMITS_STATE=invalid
  }
}

# url_host <url>: the lowercase host of an http(s) URL, brackets removed.
url_host() {
  local url=$1 rest authority host
  case "$url" in
  http://* | https://*) ;;
  *) return 1 ;;
  esac
  rest=${url#*://}
  authority=${rest%%[/?#]*}
  authority=${authority##*@}
  case "$authority" in
  \[*) host=${authority#\[}; host=${host%%\]*} ;;
  *) host=${authority%%:*} ;;
  esac
  [ -n "$host" ] || return 1
  printf '%s\n' "$host" | tr '[:upper:]' '[:lower:]'
}

host_is_local() {
  local host=$1 a b
  case "$host" in
  localhost | *.localhost | *.local | *.lan | *.internal | *.home.arpa) return 0 ;;
  ::1 | 0:0:0:0:0:0:0:1) return 0 ;;
  f[cd][0-9a-f][0-9a-f]:* | f[cd][0-9a-f]:* | f[cd]:*) return 0 ;;
  fe[89ab][0-9a-f]:*) return 0 ;;
  esac
  if [[ $host =~ ^([0-9]{1,3})\.([0-9]{1,3})\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    a=$((10#${BASH_REMATCH[1]}))
    b=$((10#${BASH_REMATCH[2]}))
    case "$a" in
    127 | 10) return 0 ;;
    0) [ "$host" = 0.0.0.0 ] ;;
    172) [ "$b" -ge 16 ] && [ "$b" -le 31 ] ;;
    192) [ "$b" -eq 168 ] ;;
    169) [ "$b" -eq 254 ] ;;
    100) [ "$b" -ge 64 ] && [ "$b" -le 127 ] ;;
    *) return 1 ;;
    esac
    return
  fi
  case "$host" in
  *.* | *:*) return 1 ;;
  esac
  return 0
}

base_is_local() {
  local host
  host=$(url_host "$1") || return 1
  host_is_local "$host"
}

# model_matches <model>: provider<TAB>id<TAB>baseUrl for each provider entry in
# models.json the model can resolve to.
model_matches() {
  jq -r --arg m "$1" '
    def models($p): if ($p.models | type) == "array" then [$p.models[] | select(type == "object" and (.id | type) == "string")] else [] end;
    def base($p; $e): (if ($e.baseUrl | type) == "string" then $e.baseUrl elif ($p.baseUrl | type) == "string" then $p.baseUrl else "" end);
    .providers as $ps
    | ([ $ps | to_entries[] | select(.value | type == "object") ]) as $entries
    | ( if ($m | contains("/")) then ($m | split("/")) as $parts | $parts[0] as $prov | ($parts[1:] | join("/")) as $id
          | [ $entries[] | select(.key == $prov) | .value as $p
              | ([ models($p)[] | select(.id == $id or .id == ($id | sub(":[^:/]*$"; ""))) ] | first) as $e
              | [$prov, ($e.id // $id), base($p; ($e // {}))] ]
        else [] end ) as $prefixed
    | if ($prefixed | length) > 0 then $prefixed[]
      else $entries[] | .key as $prov | .value as $p
        | models($p)[] | select(.id == $m or .id == ($m | sub(":[^:/]*$"; ""))) | [$prov, .id, base($p; .)]
      end
    | @tsv
  ' <<<"$MODELS_JSON" 2>/dev/null
}

any_local_provider() {
  local base
  while IFS= read -r base; do
    [ -n "$base" ] || continue
    if base_is_local "$base"; then
      return 0
    fi
  done < <(jq -r '.providers[]? | select(type == "object") | (.baseUrl // empty), ((.models // [])[]? | select(type == "object") | .baseUrl // empty) | select(type == "string")' <<<"$MODELS_JSON" 2>/dev/null)
  return 1
}

# resolve <harness> <model>: sets R_KIND (local|not-local|unknown|unchecked),
# R_PROVIDER, R_ID, R_BASE, and R_DETAIL.
resolve() {
  local harness=$1 model=$2 matches provider id base count=0 locals=0 default_note=
  R_KIND='' R_PROVIDER='' R_ID='' R_BASE='' R_DETAIL=''
  case "$harness" in
  pi | pi-signed) ;;
  *)
    R_KIND=not-local
    R_DETAIL="$harness does not read Pi's model configuration"
    return
    ;;
  esac
  if [ "$CONFIG_STATE" = invalid ]; then
    R_KIND=unchecked
    R_DETAIL="$CONFIG_DETAIL, so whether this launch uses a local model server cannot be established"
    return
  fi
  if [ -z "$model" ] || [ "$model" = default ]; then
    model=$(jq -r '
      if (.defaultProvider | type) == "string" and (.defaultModel | type) == "string"
      then "\(.defaultProvider)/\(.defaultModel)" else empty end' <<<"$SETTINGS_JSON" 2>/dev/null)
    if [ -z "$model" ]; then
      if any_local_provider; then
        R_KIND=unknown
        R_DETAIL="no model is named and $AGENT_DIR/settings.json sets no default, so Pi may pick a model from a local provider"
      else
        R_KIND=not-local
        R_DETAIL="no model is named and no local provider is configured"
      fi
      return
    fi
    default_note=" (Pi's default model)"
  fi
  matches=$(model_matches "$model")
  while IFS=$'\t' read -r provider id base; do
    [ -n "$provider" ] || continue
    count=$((count + 1))
    if [ -n "$base" ] && base_is_local "$base"; then
      locals=$((locals + 1))
      R_PROVIDER=$provider R_ID=$id R_BASE=${base%/}
    fi
  done <<<"$matches"
  if [ "$locals" -gt 1 ]; then
    R_KIND=unknown
    R_DETAIL="$model$default_note matches more than one local provider, so the server it would use is ambiguous"
    return
  fi
  if [ "$locals" -eq 1 ]; then
    R_KIND=local
    R_DETAIL=$default_note
    return
  fi
  R_KIND=not-local
  if [ "$count" -gt 0 ]; then
    R_DETAIL="$model$default_note resolves to a provider without a local base URL"
  else
    R_DETAIL="$model$default_note names no locally served provider in $AGENT_DIR/models.json"
  fi
}

# probe <base>: sets P_STATE (ok|unreachable|unknown), P_DETAIL, and P_BODY,
# issuing at most one request per server per invocation.
probe() {
  local base=$1 key dir rc code
  key=$(printf '%s' "$base" | cksum | awk '{ print $1 "-" $2 }')
  dir="$WORK/$key"
  P_BODY="$dir/body"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
    printf '%s\n' "$base" > "$dir/base"
    if ! command -v curl >/dev/null 2>&1; then
      printf 'nocurl\n' > "$dir/rc"
    else
      code=$(curl -sS --noproxy '*' --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" \
        -H 'Accept: application/json' -o "$dir/body" -w '%{http_code}' \
        "$base/models" 2>/dev/null </dev/null)
      rc=$?
      printf '%s\n' "$rc" > "$dir/rc"
      printf '%s\n' "$code" > "$dir/code"
    fi
  fi
  rc=$(cat "$dir/rc")
  code=$(cat "$dir/code" 2>/dev/null || true)
  P_STATE=unknown
  case "$rc" in
  nocurl) P_DETAIL="curl is not installed, so $base could not be asked"; return ;;
  0) ;;
  6) P_STATE=unreachable P_DETAIL="the local model server $base is unreachable (its host name does not resolve)"; return ;;
  7) P_STATE=unreachable P_DETAIL="the local model server $base is unreachable (no connection)"; return ;;
  28) P_STATE=unreachable P_DETAIL="the local model server $base is unreachable (no answer within ${TIMEOUT}s)"; return ;;
  *) P_STATE=unreachable P_DETAIL="the local model server $base is unreachable (curl exit $rc)"; return ;;
  esac
  case "$code" in
  200) ;;
  401 | 403) P_DETAIL="$base needs credentials to list its models (HTTP $code), so its load state is unknown"; return ;;
  *) P_DETAIL="$base answered its model list with HTTP $code, so its load state is unknown"; return ;;
  esac
  if ! jq -e '(.data | type) == "array"' "$P_BODY" >/dev/null 2>&1; then
    P_DETAIL="$base did not answer with an OpenAI-compatible model list, so its load state is unknown"
    return
  fi
  P_STATE=ok
}

# The probed model list as entries {id, canon, aliases, st, own}: canon joins a
# llama-swap alias row to its model, aliases are the names llama-swap lists
# under the model itself, st is status.value or null, and own is false for a
# llama-swap selector or peer entry, which is never a loaded local model.
# hits($e; $id) are the entries a model id names, real models first; canon_of
# is the served model it names. names renders canonical ids with their aliases.
# shellcheck disable=SC2016  # jq, not the shell, expands these names.
LISTING_JQ='
  def st: if (.status | type) == "object" and (.status.value | type) == "string" then .status.value else null end;
  def canon: if (.meta.llamaswap.modelID | type) == "string" then .meta.llamaswap.modelID else .id end;
  def entries: [ .data[] | select(type == "object" and (.id | type) == "string")
    | {id, canon: canon, st: st,
       aliases: [ (.meta.llamaswap.aliases // []) | if type == "array" then .[] else empty end | strings ],
       own: ((.meta.llamaswap.type // "") | IN("selector", "peer") | not)} ];
  def hits($e; $id): [ $e[] | select(.id == $id or .canon == $id or any(.aliases[]; . == $id)) ] | sort_by(.own | not);
  def canon_of($e; $id): hits($e; $id)[0].canon // $id;
  def names($e): map(. as $c | ([ $e[] | select(.canon == $c) | (select(.id != $c) | .id), .aliases[] ] | unique) as $aliases
    | if ($aliases | length) > 0 then "\($c) (\($aliases | join(", ")))" else $c end) | join(", ");
'

# assess <base> <id> <key> <records-json>: verdict<TAB>short<TAB>detail from
# the probed model list and this home's local session records on that server;
# the --task record, flagged self, only marks which loaded model it replaces.
assess() {
  jq -r --arg id "$2" --arg base "$1" --arg key "$3" --arg task "$TASK" --argjson recs "$4" --argjson limits "$LIMITS_JSON" "$LISTING_JQ"'
    entries as $all
    | ($all | map(select(.own))) as $e
    | hits($all; $id) as $named
    | ($named[0].canon // $id) as $mine
    | ([ $all[] | select(.id == $mine) ] + $named | sort_by(.own | not)) as $hit
    | ($recs | map(. + {canon: canon_of($all; .id)})) as $r
    | ($r | map(select(.self)) | map(.canon)) as $own
    | ($r | map(select(.self | not))) as $r
    | ($r | map(select(.canon == $mine)) | map(.task)) as $same
    | ($r | map(select(.canon != $mine))) as $away
    | ($limits[$key] // null) as $limit
    | ($e | map(select(.canon != $mine and (.st == "loaded" or .st == "loading"))) | map(.canon) | unique) as $loaded
    | ($loaded - $own) as $others
    | ($e | map(select(.st != null and ([.st] | inside(["loaded", "loading", "unloaded"]) | not)))) as $odd
    | if ($hit | length) == 0 then
        ["unavailable", "not offered", "\($base) is reachable but does not offer \($id)"]
      elif $hit[0].st == "loaded" then
        ["ready", "loaded", "\($id) is already loaded on \($base), so no model switch is needed; the server does not report free sessions, so spare capacity is unconfirmed"]
      elif $hit[0].st == "loading" then
        ["busy", "loading", "\($id) is still loading on \($base) for another client; recheck shortly"]
      elif $hit[0].st == "unloaded" and ($others | length) > 0 then
        ["busy", "would switch the loaded model", "\($others | names($e)) is loaded on \($base); starting \($id) would make the server switch models and interrupt the sessions using it"]
      elif $hit[0].st == "unloaded" and ($odd | length) > 0 then
        ["unknown", "load state unknown", "\($base) reports unrecognized load state \($odd[0].st) for \($odd[0].id), so a model switch cannot be ruled out"]
      elif $hit[0].st == "unloaded" and any($e[]; .st == null) then
        ["unknown", "load state unknown", "\($base) reports load state for only some models, so a model switch cannot be ruled out"]
      elif $hit[0].st == "unloaded" and ($loaded | length) > 0 then
        ["ready", "replaces its own session", "\($loaded | names($e)) is loaded on \($base) only for the session of task \($task), which this relaunch replaces, so starting \($id) interrupts no other session of this home"]
      elif $hit[0].st == "unloaded" then
        ["ready", "idle", "nothing is loaded on \($base), so starting \($id) interrupts no session"]
      elif $hit[0].st != null then
        ["unknown", "load state unknown", "\($base) reports unrecognized load state \($hit[0].st) for \($id), so a model switch cannot be ruled out"]
      elif all($e[]; .st == null) and ($e | map(.canon) | unique | length) == 1 then
        ["ready", "only model", "\($id) is the only model \($base) offers, so no model switch is possible; spare capacity is unconfirmed"]
      else
        ["unknown", "load state unknown", "\($base) offers \($e | length) models without reporting which is loaded, so a model switch cannot be ruled out"]
      end
    | if .[0] == "ready" and ($away | length) > 0 then
        ["busy", "would switch models under a session",
         "task(s) \($away | map("\(.task) (\(.canon))") | join(", ")) use another model of \($base); starting \($id) would make the server switch models under them"]
      elif .[0] == "ready" and $limit != null and ($same | length) >= $limit then
        ["full", "\($same | length)/\($limit) sessions in use",
         "\($same | length) of \($limit) sessions for \($key) are in use by task(s) \($same | join(", ")); wait for one to finish or tear down a stale record, or use another candidate"]
      else . end
    | @tsv
  ' "$P_BODY" 2>/dev/null || printf 'unknown\tload state unknown\t%s could not be read, so a model switch cannot be ruled out\n' "$1"
}

# session_records <base>: a JSON array of {task, id, self} for every local task
# record of this home whose Pi launch resolves to a model of <base>; self marks
# the --task record.
# Run it in a command substitution: resolving each record overwrites the R_*.
session_records() {
  local base=$1 meta task harness model
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    task=${meta##*/}
    task=${task%.meta}
    [ -z "$(awk -F= '$1 == "remote_host" { v = substr($0, 13) } END { print v }' "$meta")" ] || continue
    harness=$(awk -F= '$1 == "harness" { v = substr($0, 9) } END { print v }' "$meta")
    model=$(awk -F= '$1 == "model" { v = substr($0, 7) } END { print v }' "$meta")
    resolve "$harness" "$model"
    [ "$R_KIND" = local ] && [ "$R_BASE" = "$base" ] || continue
    printf '%s\t%s\t%s\n' "$task" "$R_ID" "$([ "$task" = "$TASK" ] && echo true || echo false)"
  done | jq -Rnc '[inputs | split("\t") | {task: .[0], id: .[1], self: (.[2] == "true")}]'
}

# verdict <harness> <model>: sets V_VERDICT, V_SHORT, V_DETAIL, and the R_* of
# the resolution.
verdict() {
  resolve "$1" "$2"
  V_SHORT=
  case "$R_KIND" in
  not-local | unknown | unchecked)
    V_VERDICT=$R_KIND
    V_DETAIL=$R_DETAIL
    [ "$R_KIND" != unknown ] || V_SHORT="configuration ambiguous"
    [ "$R_KIND" != unchecked ] || V_SHORT="configuration unreadable"
    return
    ;;
  esac
  if [ "$LIMITS_STATE" = invalid ]; then
    V_VERDICT=unknown
    V_SHORT="session limits malformed"
    V_DETAIL="$CONFIG/crew-dispatch.json does not declare localSessions as provider/id keys with positive integer limits, so the session limit of $R_PROVIDER/$R_ID cannot be established"
    return
  fi
  probe "$R_BASE"
  case "$P_STATE" in
  unreachable)
    V_VERDICT=unavailable
    V_SHORT=unreachable
    V_DETAIL="$P_DETAIL; start it and recheck before handing work to a local worker, or use a cloud candidate"
    ;;
  unknown)
    V_VERDICT=unknown
    V_SHORT="load state unknown"
    V_DETAIL=$P_DETAIL
    ;;
  ok)
    IFS=$'\t' read -r V_VERDICT V_SHORT V_DETAIL < <(assess "$R_BASE" "$R_ID" "$R_PROVIDER/$R_ID" "$(session_records "$R_BASE")")
    ;;
  esac
  [ -z "$R_DETAIL" ] || V_DETAIL="$R_PROVIDER/$R_ID$R_DETAIL: $V_DETAIL"
}

split_candidate() {  # <spec> -> C_HARNESS C_MODEL
  C_HARNESS=${1%%:*}
  C_MODEL=
  case "$1" in *:*) C_MODEL=${1#*:} ;; esac
}

cmd_check() {
  local spec rc=0
  [ "$#" -gt 0 ] || die "check needs at least one <harness>[:<model>] candidate"
  for spec in "$@"; do
    case "${spec%%:*}" in
    '' | *[!A-Za-z0-9._-]*) die "invalid candidate harness: $spec" ;;
    esac
    case "$spec" in
    *[[:cntrl:]]*) die "invalid candidate: control characters in $spec" ;;
    esac
  done
  for spec in "$@"; do
    split_candidate "$spec"
    verdict "$C_HARNESS" "$C_MODEL"
    printf 'local-model: %s %s: %s\n' "$spec" "$V_VERDICT" "$V_DETAIL"
    case "$V_VERDICT" in
    ready | not-local | unchecked) ;;
    *) rc=1 ;;
    esac
  done
  return "$rc"
}

cmd_observe() {
  local rules=$1 profiles harness model key servers='' server ready notnow line
  [ -f "$rules" ] && [ -r "$rules" ] || return 0
  profiles=$(jq -r '
    def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
    [ ((.rules // []) | if type == "array" then .[] else empty end | select(type == "object") | profiles(.use)[]),
      profiles(.default)[] ]
    | map(select(type == "object" and (.harness == "pi" or .harness == "pi-signed")))
    | map([.harness, (if (.model | type) == "string" then .model else "" end)])
    | unique_by(.[1]) | .[] | @tsv
  ' "$rules" 2>/dev/null) || return 0
  [ -n "$profiles" ] || return 0
  if [ "$CONFIG_STATE" = invalid ]; then
    printf 'local models: %s, so no local dispatch candidate can be vouched for; every local handoff is rechecked first\n' "$CONFIG_DETAIL"
    return 0
  fi
  while IFS=$'\t' read -r harness model; do
    [ -n "$harness" ] || continue
    resolve "$harness" "$model"
    [ "$R_KIND" = local ] || continue
    if [ "$LIMITS_STATE" = invalid ]; then
      printf 'local models: the localSessions session limits in %s are malformed, so no local dispatch candidate can be vouched for; every local handoff is rechecked first\n' "$CONFIG/crew-dispatch.json"
      return 0
    fi
    verdict "$harness" "$model"
    key=$(printf '%s' "$R_BASE" | cksum | awk '{ print $1 "-" $2 }')
    case " $servers " in *" $key "*) ;; *) servers="$servers $key" ;; esac
    printf '%s\t%s\t%s\t%s\n' "$R_PROVIDER" "$R_ID" "$V_VERDICT" "$V_SHORT" >> "$WORK/$key/candidates"
  done <<<"$profiles"
  for key in $servers; do
    server=$(cat "$WORK/$key/base")
    P_BODY="$WORK/$key/body"
    probe "$server"
    if [ "$P_STATE" = unreachable ]; then
      line="local models: ${P_DETAIL#the local model server }; local candidates $(cut -f2 "$WORK/$key/candidates" | awk '!seen[$0]++' | paste -sd, - | sed 's/,/, /g') cannot take work until it is started; cloud profiles still apply, and every local handoff is rechecked first"
      printf '%s\n' "$line"
      continue
    fi
    if [ "$P_STATE" != ok ]; then
      printf 'local models: %s; local handoffs stay blocked until a recheck can rule out a model switch\n' "$P_DETAIL"
      continue
    fi
    ready=$(awk -F'\t' '$3 == "ready" && !seen[$2]++ { print $2 }' "$WORK/$key/candidates" | paste -sd, - | sed 's/,/, /g')
    notnow=$(awk -F'\t' '$3 != "ready" && !seen[$2]++ { print $2 " (" $4 ")" }' "$WORK/$key/candidates" | paste -sd, - | sed 's/,/, /g')
    line="local models: $server is reachable; loaded: $(jq -r "$LISTING_JQ"'
        (entries | map(select(.own))) as $e | [ $e[] | select(.st == "loaded") | .canon ] | unique
        | if length == 0 then (if all($e[]; .st == null) then "not reported" else "none" end) else names($e) end
      ' "$P_BODY" 2>/dev/null || printf 'unknown')"
    [ -z "$ready" ] || line="$line; ready now: $ready"
    [ -z "$notnow" ] || line="$line; not now: $notnow"
    printf '%s; every local handoff is rechecked first\n' "$line"
  done
  return 0
}

MODE=${1:-}
[ "$#" -eq 0 ] || shift
AGENT_DIR_ARG=
RULES_ARG=
ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
  --agent-dir) [ -n "${2-}" ] || die "--agent-dir needs a directory"; AGENT_DIR_ARG=$2; shift 2 ;;
  --rules) [ -n "${2-}" ] || die "--rules needs a file"; RULES_ARG=$2; shift 2 ;;
  --task) [ -n "${2-}" ] || die "--task needs a task id"; TASK=$2; shift 2 ;;
  -h | --help) usage; exit 0 ;;
  --) shift; while [ "$#" -gt 0 ]; do ARGS+=("$1"); shift; done ;;
  -*) die "unknown option: $1" ;;
  *) ARGS+=("$1"); shift ;;
  esac
done

case "$MODE" in
check | observe) ;;
-h | --help | help) usage; exit 0 ;;
*) usage >&2; exit 2 ;;
esac
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v perl >/dev/null 2>&1 || die "perl is required"
resolve_agent_dir "$AGENT_DIR_ARG"
load_config
load_limits
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-local-model.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

case "$MODE" in
check) cmd_check "${ARGS[@]+"${ARGS[@]}"}" ;;
observe)
  [ "${#ARGS[@]}" -eq 0 ] || die "observe takes no positional arguments"
  cmd_observe "${RULES_ARG:-$CONFIG/crew-dispatch.json}"
  ;;
esac
