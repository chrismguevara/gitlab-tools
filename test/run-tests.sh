#!/usr/bin/env bash
# End-to-end tests with mocked glab / opencode / mail and a local bare git "origin".
# Usage: test/run-tests.sh [-v]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; echo "tmpdir: $T"; [[ -n "${GLT_TEST_KEEP:-}" ]] || trap 'rm -rf "$T"' EXIT
[[ "${1:-}" = -v ]] && set -x
export PATH="$ROOT/test/mocks/bin:$PATH"
export GLT_CONFIG=/dev/null GLT_PROJECT=group/proj GLT_WORKDIR="$T/work" GLT_STATE_DIR="$T/state"
export GLT_GIT_REMOTE="$T/origin.git" GLT_MAIL_TO=tester GLT_BOT_USER=bot GLT_SKIP_DRAFTS=1
export GLT_TEST_FIXTURES="$T/fix" GLT_TEST_CALLS="$T/calls.log" GLT_TEST_OC_DIR="$T/oc" GLT_TEST_MAILBOX="$T/mailbox"
export GLT_OPENCODE_CONFIG="$ROOT/opencode/opencode.json"
mkdir -p "$T/fix" "$T/oc"; : > "$T/calls.log"; : > "$T/mailbox"
FAIL=0; pass() { echo "  ok   $*"; }; fail() { echo "  FAIL $*"; FAIL=1; }
assert_grep()  { grep -qE -- "$1" "$2" && pass "$3" || { fail "$3 (pattern '$1' not in $2)"; }; }
assert_nogrep(){ grep -qE -- "$1" "$2" 2>/dev/null && fail "$3 (pattern '$1' found in $2)" || pass "$3"; }
reset_state() { rm -rf "$T/state" "$T/work"; : > "$T/calls.log"; : > "$T/mailbox"; rm -rf "$T/oc"; mkdir -p "$T/oc"; }

# ---------------------------------------------------------------- git origin
git init -q --bare "$T/origin.git"
W="$T/seed"; git clone -q "$T/origin.git" "$W" 2>/dev/null; git -C "$W" config user.email t@t; git -C "$W" config user.name t
printf 'line1\nline2\nline3\nline4\nline5\n' > "$W/a.txt"; echo "foo" > "$W/b.txt"; echo "c" > "$W/c.txt"
git -C "$W" add -A && git -C "$W" commit -qm "init" && git -C "$W" branch -M main && git -C "$W" push -q origin main
mkbranch() { git -C "$W" checkout -q main && git -C "$W" checkout -qb "$1" && (cd "$W" && eval "$2") && git -C "$W" add -A && git -C "$W" commit -qm "$1 work" && git -C "$W" push -q origin "$1"; }
mkbranch feat  'echo bar >> b.txt'
mkbranch feat2 'sed -i s/line3/line3-feat2/ a.txt'
mkbranch feat3 'sed -i s/line3/line3-feat3/ a.txt'
git -C "$W" checkout -q main && echo "c2" >> "$W/c.txt" && git -C "$W" commit -qam "main moves (c.txt)" && git -C "$W" push -q origin main
git -C "$W" checkout -q main && sed -i s/line3/line3-main/ "$W/a.txt" && git -C "$W" commit -qam "main edits a.txt line3" && git -C "$W" push -q origin main
MAIN_SHA="$(git -C "$W" rev-parse main)"

mr_json() { # mr_json <iid> <branch> [pipeline-json]
  jq -n --argjson iid "$1" --arg b "$2" --argjson p "${3:-null}" --arg sha "$(git -C "$W" rev-parse "origin/$2")" '
    {iid:$iid, state:"opened", title:("MR " + $b), source_branch:$b, target_branch:"main", sha:$sha, draft:false, work_in_progress:false,
     web_url:("https://gitlab.example/group/proj/-/merge_requests/" + ($iid|tostring)), author:{username:"bot"}, labels:[],
     source_project_id:1, target_project_id:1, head_pipeline:$p, updated_at:"2026-01-01T00:00:00Z", detailed_merge_status:"mergeable",
     has_conflicts:false, blocking_discussions_resolved:true}'; }
echo '{"id":1,"default_branch":"main","ssh_url_to_repo":"git@gitlab.example:group/proj.git"}' > "$T/fix/project.json"
echo '{"username":"bot"}' > "$T/fix/user.json"

# ====================================================== 1. clean rebase (0 LLM)
echo "## rebase: clean"; reset_state
jq -s . <(mr_json 1 feat) > "$T/fix/mr_list.json"
"$ROOT/bin/glt-mr-rebase" 2>"$T/log1"
git -C "$W" fetch -q origin
git -C "$W" merge-base --is-ancestor "$MAIN_SHA" origin/feat && pass "origin/feat rebased onto main" || fail "origin/feat not rebased"
[[ "$(git -C "$W" rev-list --count main..origin/feat)" = 1 ]] && pass "feature commit preserved" || fail "unexpected commit count"
[[ ! -f "$T/oc/glt-planner.count" && ! -f "$T/oc/glt-resolver.count" ]] && pass "no opencode call" || fail "opencode was called"
assert_grep 'api POST projects/group%2Fproj/merge_requests/1/notes' "$T/calls.log" "note posted on MR"
"$ROOT/bin/glt-mr-rebase" 2>"$T/log1b"; assert_grep 'up to date' <(GLT_VERBOSE=1 "$ROOT/bin/glt-mr-rebase" 2>&1) "second run is a no-op"

# ====================================================== 2. conflict -> plan
echo "## rebase: conflict, mode=plan"; reset_state
jq -s . <(mr_json 2 feat2) > "$T/fix/mr_list.json"; echo "PLAN-TEXT-FROM-MODEL" > "$T/oc/glt-planner.response"
GLT_REBASE_CONFLICT_MODE=plan "$ROOT/bin/glt-mr-rebase" 2>"$T/log2"
assert_grep 'PLAN-TEXT-FROM-MODEL' "$T/mailbox" "plan mailed"
assert_grep 'Conflict hunks' "$T/mailbox" "conflict hunks mailed"
assert_grep 'line3-feat2' "$T/oc/glt-planner.prompt" "planner prompt carries the conflict"
git -C "$W" fetch -q origin; [[ "$(git -C "$W" rev-parse origin/feat2)" = "$(jq -r '.[0].sha' "$T/fix/mr_list.json")" ]] && pass "branch untouched" || fail "branch was pushed"
"$ROOT/bin/glt-mr-rebase" 2>>"$T/log2"; [[ "$(cat "$T/oc/glt-planner.count")" = 1 ]] && pass "same conflict not retried (state)" || fail "planner called again"

# ====================================================== 3. conflict -> resolve
echo "## rebase: conflict, mode=resolve"; reset_state
jq -s . <(mr_json 3 feat3) > "$T/fix/mr_list.json"
printf 'a.txt: kept both edits\nUNRESOLVED: none\n' > "$T/oc/glt-resolver.response"
cat > "$T/oc/glt-resolver.sh" <<'EOS'
#!/usr/bin/env bash
printf 'line1\nline2\nline3-main-feat3\nline4\nline5\n' > a.txt
EOS
chmod +x "$T/oc/glt-resolver.sh"
GLT_REBASE_CONFLICT_MODE=resolve GLT_VERIFY_CMD='grep -q line3-main-feat3 a.txt' "$ROOT/bin/glt-mr-rebase" 2>"$T/log3"
git -C "$W" fetch -q origin
git -C "$W" merge-base --is-ancestor "$MAIN_SHA" origin/feat3 && pass "origin/feat3 rebased" || fail "feat3 not rebased: $(tail -5 "$T/log3")"
[[ "$(git -C "$W" show origin/feat3:a.txt | sed -n 3p)" = "line3-main-feat3" ]] && pass "resolution pushed" || fail "resolution content wrong"
assert_grep 'conflict resolution - please review' "$T/mailbox" "summary mailed"
assert_grep 'merge_requests/3/notes' "$T/calls.log" "MR note posted"

# ====================================================== 3b. resolve fails verify -> nothing pushed
echo "## rebase: resolve but verify fails"; reset_state
git -C "$W" checkout -q main && git -C "$W" checkout -qb feat4 && sed -i s/line3-main/line3-feat4/ "$W/a.txt" && git -C "$W" commit -qam feat4 && git -C "$W" push -q origin feat4
git -C "$W" checkout -q main && sed -i s/line3-main/line3-main2/ "$W/a.txt" && git -C "$W" commit -qam main3 && git -C "$W" push -q origin main
jq -s . <(mr_json 4 feat4) > "$T/fix/mr_list.json"; cp "$T/oc/../oc/glt-resolver.sh" "$T/oc/" 2>/dev/null || true
printf 'a.txt: merged\nUNRESOLVED: none\n' > "$T/oc/glt-resolver.response"; printf '#!/usr/bin/env bash\nprintf "line1\\nline2\\nX\\nline4\\nline5\\n" > a.txt\n' > "$T/oc/glt-resolver.sh"; chmod +x "$T/oc/glt-resolver.sh"
before="$(git -C "$W" rev-parse origin/feat4)"
GLT_REBASE_CONFLICT_MODE=resolve GLT_VERIFY_CMD='false' "$ROOT/bin/glt-mr-rebase" 2>"$T/log3b"
git -C "$W" fetch -q origin; [[ "$(git -C "$W" rev-parse origin/feat4)" = "$before" ]] && pass "nothing pushed when verify fails" || fail "pushed despite failing verify"
assert_grep 'verification failed' "$T/mailbox" "failure mailed"

# ====================================================== 4. comments
echo "## comments"; reset_state
jq -s . <(mr_json 1 feat) > "$T/fix/mr_list.json"
note() { jq -n --argjson id "$1" --arg u "$2" --arg b "$3" --argjson res "${4:-false}" --argjson sys "${5:-false}" --argjson pos "${6:-null}" --argjson sug "${7:-[]}" \
  '{id:$id, author:{username:$u}, body:$b, system:$sys, resolvable:true, resolved:$res, created_at:"2026-01-02T00:00:00Z", position:$pos, suggestions:$sug}'; }
jq -n --argjson n1 "$(note 101 alice 'Use this instead:\n```suggestion\nbaz\n```' false false '{"new_path":"b.txt","new_line":1}' '[{"id":501,"applied":false,"appliable":true}]')" \
      --argjson n2 "$(note 102 alice 'Why do we retry here?')" \
      --argjson n3 "$(note 103 alice 'nit: rename foo to bar' false false '{"new_path":"b.txt","new_line":1}')" \
      --argjson n4 "$(note 104 alice 'Please split this into a service class and add tests')" \
      --argjson n5 "$(note 105 alice 'LGTM')" \
      --argjson n6 "$(note 106 alice 'old thread' true)" \
      --argjson n7a "$(note 107 alice 'ping?')" --argjson n7b "$(note 108 bot 'answered')" \
      --argjson n8 "$(note 109 alice 'changed the description' false true)" '
  [{id:"d1",notes:[$n1]},{id:"d2",notes:[$n2]},{id:"d3",notes:[$n3]},{id:"d4",notes:[$n4]},{id:"d5",notes:[$n5]},
   {id:"d6",notes:[$n6]},{id:"d7",notes:[$n7a,$n7b]},{id:"d8",notes:[$n8]}]' > "$T/fix/merge_requests_1_discussions.json"
cat > "$T/oc/glt-classifier.response" <<'EOS'
Here you go:
```json
[{"id":"102","kind":"question","summary":"asks about retry","reply":"We retry because the upstream API is flaky; see RETRY_POLICY in config."},
 {"id":"103","kind":"minor_fix","summary":"Rename foo to bar in b.txt","needed":"","reply":""},
 {"id":"104","kind":"substantial","summary":"Extract a service class","needed":"New module, move logic, add tests.","reply":""}]
```
EOS
echo "Rename foo to bar in b.txt" > "$T/oc/glt-fixer.response"
printf '#!/usr/bin/env bash\nsed -i s/foo/bar/ b.txt\n' > "$T/oc/glt-fixer.sh"; chmod +x "$T/oc/glt-fixer.sh"
"$ROOT/bin/glt-mr-comments" 2>"$T/log4"
assert_grep 'api PUT projects/group%2Fproj/suggestions/501/apply' "$T/calls.log" "suggestion applied via API (0 tokens)"
[[ "$(cat "$T/oc/glt-classifier.count")" = 1 ]] && pass "one classifier call for the MR" || fail "classifier calls: $(cat "$T/oc/glt-classifier.count" 2>/dev/null)"
assert_nogrep 'LGTM' "$T/oc/glt-classifier.prompt" "LGTM not sent to the model"
assert_nogrep 'old thread|changed the description|ping\?' "$T/oc/glt-classifier.prompt" "resolved/system/answered threads filtered"
assert_grep 'id=102' "$T/oc/glt-classifier.prompt" "question sent to classifier"
assert_grep '1: foo' "$T/oc/glt-classifier.prompt" "code context included"
git -C "$W" fetch -q origin
[[ "$(git -C "$W" log -1 --format=%s origin/feat)" = "Rename foo to bar in b.txt" ]] && pass "fix committed and pushed" || fail "fix commit missing: $(git -C "$W" log -1 --format=%s origin/feat)"
[[ "$(git -C "$W" show origin/feat:b.txt | head -1)" = bar ]] && pass "fix content pushed" || fail "fix content wrong"
assert_grep 'discussions/d3/notes body=.*Addressed in' "$T/calls.log" "reply posted on fixed thread"
assert_nogrep 'discussions/d3 resolved' "$T/calls.log" "thread not auto-resolved by default"
assert_grep 'Needs your decision' "$T/mailbox" "substantial -> mail"
assert_grep 'Extract a service class' "$T/mailbox" "substantial summary in mail"
assert_grep 'Suggested reply: We retry because' "$T/mailbox" "question -> drafted reply in mail"
assert_grep 'glt-reply 1 d2' "$T/mailbox" "reply command in mail"
assert_grep 'Auto-fixed and pushed' "$T/mailbox" "auto-fix reported"
"$ROOT/bin/glt-mr-comments" 2>>"$T/log4"
[[ "$(cat "$T/oc/glt-classifier.count")" = 1 ]] && pass "second run: nothing re-classified" || fail "classifier called again"

# ---- heuristic-only mode and escalation when fixer touches too much
echo "## comments: fixer escalation"; reset_state
jq -s . <(mr_json 1 feat) > "$T/fix/mr_list.json"
jq -n --argjson n3 "$(note 203 alice 'nit: tweak' false false '{"new_path":"b.txt","new_line":1}')" '[{id:"d3",notes:[$n3]}]' > "$T/fix/merge_requests_1_discussions.json"
echo '[{"id":"203","kind":"minor_fix","summary":"tweak"}]' > "$T/oc/glt-classifier.response"
echo "ESCALATE: this is actually a large change" > "$T/oc/glt-fixer.response"; rm -f "$T/oc/glt-fixer.sh"
before="$(git -C "$W" rev-parse origin/feat)"
"$ROOT/bin/glt-mr-comments" 2>"$T/log4b"
git -C "$W" fetch -q origin; [[ "$(git -C "$W" rev-parse origin/feat)" = "$before" ]] && pass "escalated fix: nothing pushed" || fail "pushed on escalate"
assert_grep 'this is actually a large change' "$T/mailbox" "escalation reason mailed"

# ====================================================== 5. CI triage
echo "## ci triage"; reset_state
jq -s . <(mr_json 1 feat '{"id":55,"status":"failed"}') > "$T/fix/mr_list.json"
echo '[{"id":7,"name":"unit","stage":"test","failure_reason":"script_failure","web_url":"u7","allow_failure":false},
      {"id":8,"name":"lint","stage":"test","failure_reason":"script_failure","web_url":"u8","allow_failure":false}]' > "$T/fix/pipelines_55_jobs.json"
printf 'fetching deps\nError: Connection reset by peer\nERROR: Job failed\n' > "$T/fix/jobs_7_trace.txt"
printf 'running eslint\n\x1b[31m  12:3  error  Missing semicolon  semi\x1b[0m\nERROR: Job failed: exit code 1\n' > "$T/fix/jobs_8_trace.txt"
echo '{"category":"lint","root_cause":"Missing semicolon in src/x.js:12","fix_suggestion":"add ;","auto_fixable":true,"files":["src/x.js"]}' > "$T/oc/glt-summarizer.response"
"$ROOT/bin/glt-ci-triage" 2>"$T/log5"
assert_grep 'api POST projects/group%2Fproj/jobs/7/retry' "$T/calls.log" "flaky job retried (0 tokens)"
assert_nogrep 'jobs/8/retry' "$T/calls.log" "real failure not retried"
assert_grep 'Category: lint' "$T/mailbox" "triage mailed"
assert_grep 'Missing semicolon' "$T/oc/glt-summarizer.prompt" "log tail sent (ANSI stripped)"
assert_nogrep $'\x1b' "$T/oc/glt-summarizer.prompt" "ANSI escapes stripped"
[[ ! -f "$T/oc/glt-fixer.count" ]] && pass "no autofix unless GLT_CI_AUTOFIX=1" || fail "fixer ran"
"$ROOT/bin/glt-ci-triage" 2>>"$T/log5"; [[ "$(cat "$T/oc/glt-summarizer.count")" = 1 ]] && pass "pipeline triaged once" || fail "re-triaged"

# ====================================================== 6. issue -> draft MR
echo "## issue to mr"; reset_state
echo '[{"iid":9,"title":"Add --version flag","description":"Print the version and exit.","web_url":"https://gitlab.example/group/proj/-/issues/9","labels":["opencode"]}]' > "$T/fix/issues.json"
echo "Implemented --version.

- cli.sh" > "$T/oc/glt-implementer.response"
printf '#!/usr/bin/env bash\necho "echo 1.0" > cli.sh\n' > "$T/oc/glt-implementer.sh"; chmod +x "$T/oc/glt-implementer.sh"
"$ROOT/bin/glt-issue-to-mr" 2>"$T/log6"
git -C "$W" fetch -q origin
git -C "$W" rev-parse -q --verify origin/glt/issue-9 >/dev/null && pass "branch pushed" || fail "branch missing: $(tail -3 "$T/log6")"
assert_grep 'api POST projects/group%2Fproj/merge_requests source_branch=glt/issue-9 target_branch=main title=Draft: Add --version flag' "$T/calls.log" "draft MR created"
assert_grep 'api PUT projects/group%2Fproj/issues/9 add_labels=opencode::mr-created remove_labels=opencode' "$T/calls.log" "issue relabelled"
assert_grep 'draft MR created' "$T/mailbox" "mail sent"
assert_grep 'Implement GitLab issue #9' "$T/oc/glt-implementer.prompt" "prompt built"

# ====================================================== 7. digest
echo "## digest"; reset_state
jq -s . <(mr_json 1 feat '{"id":56,"status":"success"}') > "$T/fix/mr_list.json"
"$ROOT/bin/glt-mr-digest" 2>"$T/log7"
assert_grep 'GitLab digest for @bot' "$T/mailbox" "digest mailed"
assert_grep 'ready to merge' "$T/mailbox" "sections present"
[[ ! -f "$T/oc/glt-summarizer.count" ]] && pass "digest used no tokens" || fail "digest called the model"

# ====================================================== 8. dry run
echo "## dry-run"; reset_state
jq -s . <(mr_json 1 feat) > "$T/fix/mr_list.json"
git -C "$W" checkout -q main && echo "c3" >> "$W/c.txt" && git -C "$W" commit -qam "main moves again" && git -C "$W" push -q origin main
before="$(git -C "$W" rev-parse origin/feat)"
"$ROOT/bin/glt-mr-rebase" --dry-run 2>"$T/log8"
git -C "$W" fetch -q origin; [[ "$(git -C "$W" rev-parse origin/feat)" = "$before" ]] && pass "dry-run pushes nothing" || fail "dry-run pushed"
assert_grep 'dry-run: git push' "$T/log8" "dry-run logs the push"

echo; [[ $FAIL = 0 ]] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
