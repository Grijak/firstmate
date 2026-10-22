#!/usr/bin/env bash
# Contract: parsed .no-mistakes.yaml must leave commands.test absent or empty,
# and must keep test evidence and the intent text off public PR surfaces.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM="$ROOT/.no-mistakes.yaml"

test_nm_has_no_deterministic_test_command() {
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this contract"
  local val
  val=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
cmds = doc["commands"] || {}
val = cmds.is_a?(Hash) ? cmds["test"] : nil
puts (val.nil? || val == false || val == "") ? "" : val.inspect
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  if [ -n "$val" ]; then
    fail "commands.test must be absent or empty so Test stays intent-targeted; got: $val"
  fi
  pass "no-mistakes does not configure commands.test"
}

# The repository is public, so evidence must stay on local disk: no orphan
# evidence branch, no GitHub media upload, and no generated Intent section.
# Each value must be an explicit false; an absent attach_media or
# publish_intent defaults to publishing.
test_nm_keeps_evidence_private() {
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this contract"
  local out
  out=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
dig = lambda do |*keys|
  keys.reduce(doc) { |node, key| node.is_a?(Hash) ? node[key] : nil }
end
{
  "test.evidence.store_in_repo" => dig.call("test", "evidence", "store_in_repo"),
  "test.evidence.attach_media" => dig.call("test", "evidence", "attach_media"),
  "pr.publish_intent" => dig.call("pr", "publish_intent"),
}.each { |key, val| puts "#{key}=#{val.inspect}" unless val == false }
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  if [ -n "$out" ]; then
    fail "these settings must be explicitly false so no-mistakes keeps evidence private: $(printf '%s' "$out" | tr '\n' ' ')"
  fi
  pass "no-mistakes keeps test evidence and intent off public PR surfaces"
}

test_nm_has_no_deterministic_test_command
test_nm_keeps_evidence_private
