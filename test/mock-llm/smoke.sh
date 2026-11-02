#!/usr/bin/env bash
# Smoke-test the REAL opencode binary against opencode/opencode.json using a local
# mock OpenAI-compatible server, so no tokens are spent:
#   * every glt-* agent is listed by `opencode agent list`
#   * prompt files resolve ({file:./prompts/...}) and reach the model as the system prompt
#   * the classifier has no tools, the fixer has bash limited to read-only git
#   * --title suppresses the title-generation call; --format json is parseable
# Requires: opencode, python3, jq.  Usage: test/mock-llm/smoke.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"; trap 'kill "${SRV:-}" 2>/dev/null || true; rm -rf "$T"' EXIT
# fresh HOME (no stored credentials or sessions), but reuse the real cache so the
# @ai-sdk/openai-compatible package opencode installs on first use is not re-downloaded
export XDG_CACHE_HOME="${OPENCODE_SMOKE_CACHE:-$HOME/.cache}"
export HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_DATA_HOME="$T/home/.local/share"
export OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1 OPENCODE_DISABLE_MODELS_FETCH=1
mkdir -p "$HOME" "$T/proj" && git -C "$T/proj" init -q
PORT=$(( 20000 + RANDOM % 20000 ))
echo '[{"text":"[{\"id\":\"1\",\"kind\":\"question\",\"summary\":\"s\",\"reply\":\"r\"}]"}]' > "$T/script.json"
MOCK_PORT=$PORT MOCK_SCRIPT="$T/script.json" MOCK_LOG="$T/requests.log" python3 -I "$ROOT/test/mock-llm/mock_llm.py" & SRV=$!
sleep 1
# Overlay the mock provider onto the real config (agents, prompts, permissions unchanged).
jq --arg url "http://127.0.0.1:$PORT/v1" '
  .provider = {mock: {npm: "@ai-sdk/openai-compatible", name: "Mock", options: {baseURL: $url, apiKey: "mock"},
               models: {scripted: {name: "Scripted", tool_call: true, limit: {context: 128000, output: 8192}}}}}
  | .model = "mock/scripted" | .small_model = "mock/scripted"
  | .agent |= with_entries(.value.model = "mock/scripted")' "$ROOT/opencode/opencode.json" > "$ROOT/opencode/.smoke.opencode.json"
trap 'kill "${SRV:-}" 2>/dev/null || true; rm -rf "$T" "$ROOT/opencode/.smoke.opencode.json"' EXIT
export OPENCODE_CONFIG="$ROOT/opencode/.smoke.opencode.json"
cd "$T/proj"
fail=0; pass() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fail=1; }
agents="$(timeout 120 opencode agent list </dev/null 2>&1)"
for a in glt-classifier glt-summarizer glt-planner glt-resolver glt-fixer glt-implementer glt-reviewer; do
  grep -q "^$a" <<<"$agents" && pass "agent $a listed" || bad "agent $a missing: $agents"
done
run() { timeout 120 opencode run --agent "$1" --title "smoke-$1" --format json </dev/null "classify: id=1 'why?'" 2>"$T/$1.err" > "$T/$1.out" || { bad "$1 run failed: $(tail -3 "$T/$1.err")"; return 1; }; }
: > "$T/requests.log"; run glt-classifier && {
  jq -e 'select(.type=="text") | .part.text | test("question")' "$T/glt-classifier.out" >/dev/null && pass "classifier text event parsed" || bad "classifier output: $(cat "$T/glt-classifier.out")"
  jq -e '[.[]|select(.type=="step_finish")|.part.tokens.total]|add>0' <(jq -s . "$T/glt-classifier.out") >/dev/null && pass "token usage present in step_finish" || bad "no token usage"
  [[ "$(wc -l < "$T/requests.log")" = 1 ]] && pass "exactly one LLM call (no title call)" || bad "$(wc -l < "$T/requests.log") LLM calls"
  jq -e '.req.tools == [] or (.req.tools|length)==0' "$T/requests.log" >/dev/null && pass "classifier sent no tools" || bad "classifier tools: $(jq -c '[.req.tools[]?.function.name]' "$T/requests.log")"
  jq -e '.req.messages[0].content | tostring | test("minor_fix")' "$T/requests.log" >/dev/null && pass "classifier prompt file loaded as system prompt" || bad "system prompt missing prompt file"
}
: > "$T/requests.log"; run glt-fixer && {
  tools="$(jq -c '[.req.tools[]?.function.name]|sort' "$T/requests.log")"
  jq -e 'index("bash") and index("edit") and (index("webfetch")|not) and (index("task")|not)' <<<"$tools" >/dev/null && pass "fixer tools: $tools" || bad "fixer tools: $tools"
}
: > "$T/requests.log"; run glt-resolver && {
  tools="$(jq -c '[.req.tools[]?.function.name]|sort' "$T/requests.log")"
  jq -e '(index("bash")|not) and index("edit")' <<<"$tools" >/dev/null && pass "resolver has edit but no bash: $tools" || bad "resolver tools: $tools"
}
exit $fail
