#!/usr/bin/env bash
# lib/common.sh - shared helpers for gitlab-tools automation scripts.
#
# Source this file; do not execute it. Every script expects:
#   GLT_ROOT       - repository root of gitlab-tools (set automatically)
#   GLT_CONFIG     - optional env file (default: ~/.config/gitlab-tools/env)
#
# Design rules (see README):
#   * Everything deterministic is done with glab + git + jq. opencode is only
#     invoked when a decision or an edit genuinely needs a model.
#   * opencode always runs non-interactively (`opencode run`) with an explicit
#     agent, a fixed title (skips the title-generation LLM call), and
#     `--format json` so the result and token usage can be parsed reliably.
#   * Nothing is ever force-pushed without --force-with-lease, and nothing is
#     pushed unless VERIFY_CMD (if set) passes.

set -o pipefail

GLT_ROOT="${GLT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
GLT_CONFIG="${GLT_CONFIG:-$HOME/.config/gitlab-tools/env}"
# shellcheck disable=SC1090
[[ -f "$GLT_CONFIG" ]] && source "$GLT_CONFIG"

# ---------------------------------------------------------------------------
# Configuration with defaults (all overridable from $GLT_CONFIG or the env)
# ---------------------------------------------------------------------------
: "${GLT_PROJECT:?GLT_PROJECT (group/project path on GitLab) must be set}"
: "${GLT_WORKDIR:=$HOME/.cache/gitlab-tools}"           # clones live here
: "${GLT_STATE_DIR:=$HOME/.local/state/gitlab-tools}"    # idempotency state
: "${GLT_LOG_DIR:=$GLT_STATE_DIR/logs}"
: "${GLT_MAIL_TO:=${MAILTO:-$USER}}"                     # unix mail recipient
: "${GLT_MAIL_CMD:=}"                                    # override e.g. 'mail -s'
: "${GLT_GIT_REMOTE:=}"                                  # default: derived from glab
: "${GLT_BOT_USER:=}"                                    # GitLab username the scripts act as
: "${GLT_MR_LIST_ARGS:=--author=@me}"                    # which MRs are "ours"
: "${GLT_SKIP_DRAFTS:=1}"
: "${GLT_VERIFY_CMD:=}"                                  # e.g. 'make test' run before any push
: "${GLT_OPENCODE_BIN:=opencode}"
: "${GLT_OPENCODE_CONFIG:=$GLT_ROOT/opencode/opencode.json}"
: "${GLT_OPENCODE_TIMEOUT:=900}"                         # seconds per opencode run
: "${GLT_MAX_TOKENS_PER_RUN:=400000}"                    # soft budget per script run
: "${GLT_DRY_RUN:=0}"                                    # 1 = no push / no API writes / no mail
: "${GLT_VERBOSE:=0}"

mkdir -p "$GLT_WORKDIR" "$GLT_STATE_DIR" "$GLT_LOG_DIR"

PROJECT_SLUG="${GLT_PROJECT//\//__}"
API_PROJECT="projects/$(printf '%s' "$GLT_PROJECT" | jq -sRr @uri)"   # URL-encoded path for `glab api`
STATE="$GLT_STATE_DIR/$PROJECT_SLUG"
mkdir -p "$STATE"
TOKENS_USED=0

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log()  { printf '%s [%s] %s\n' "$(_ts)" "${SCRIPT_NAME:-glt}" "$*" >&2; }
dbg()  { [[ "$GLT_VERBOSE" = 1 ]] && log "DEBUG $*"; return 0; }
warn() { log "WARN  $*"; }
die()  { log "ERROR $*"; exit 1; }

require_cmd() {
  local c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"; done
}

# ---------------------------------------------------------------------------
# Locking (cron ticks must never overlap on the same project)
# ---------------------------------------------------------------------------
acquire_lock() {
  local name="$1" fd
  local lockfile="$STATE/${name}.lock"
  exec {fd}>"$lockfile"
  if ! flock -n "$fd"; then
    log "another $name run holds $lockfile; exiting"
    exit 0
  fi
  LOCK_FD=$fd
}

# ---------------------------------------------------------------------------
# State helpers: a flat "seen" file per topic, one key per line
# ---------------------------------------------------------------------------
state_has()  { [[ -f "$STATE/$1" ]] && grep -qxF -- "$2" "$STATE/$1"; }
state_add()  { [[ "$GLT_DRY_RUN" = 1 ]] && { dbg "dry-run: state_add $1 $2"; return 0; }; printf '%s\n' "$2" >> "$STATE/$1"; }
state_get()  { [[ -f "$STATE/$1" ]] && cat "$STATE/$1"; }
state_set()  { [[ "$GLT_DRY_RUN" = 1 ]] && return 0; printf '%s\n' "$2" > "$STATE/$1"; }

# ---------------------------------------------------------------------------
# glab wrappers
# ---------------------------------------------------------------------------
# All API access goes through `glab api` so auth/host handling is glab's job.
# GITLAB_TOKEN / GITLAB_HOST env vars are honoured by glab (ideal for cron).
gl_api() {               # gl_api <method> <path> [extra glab api args...]
  local method="$1" path="$2"; shift 2
  path="${path/#projects\/:id/$API_PROJECT}"   # allow the familiar :id shorthand
  if [[ "$GLT_DRY_RUN" = 1 && "$method" != GET ]]; then
    log "dry-run: glab api -X $method $path $*"
    echo '{}'
    return 0
  fi
  glab api -X "$method" "$path" "$@"
}
gl_api_paginated() {     # GET all pages as one JSON array
  local path="${1/#projects\/:id/$API_PROJECT}"
  glab api --paginate "$path"
}
gl_me() {                # username the token belongs to (cached)
  if [[ -n "$GLT_BOT_USER" ]]; then echo "$GLT_BOT_USER"; return; fi
  local cached="$STATE/me"
  if [[ -s "$cached" ]]; then cat "$cached"; return; fi
  glab api user | jq -r .username | tee "$cached"
}
gl_mr_list() {           # JSON array of open MRs matching GLT_MR_LIST_ARGS
  # shellcheck disable=SC2086
  glab mr list -R "$GLT_PROJECT" -F json --per-page 100 $GLT_MR_LIST_ARGS
}
gl_mr() {                # full MR JSON incl. diverged_commits_count
  gl_api GET "projects/:id/merge_requests/$1?include_diverged_commits_count=true"
}
gl_mr_note() {           # post a plain note on an MR
  local iid="$1" body="$2"
  gl_api POST "projects/:id/merge_requests/$iid/notes" -f "body=$body" >/dev/null
}
gl_discussion_reply() {  # reply inside an existing discussion thread
  local iid="$1" did="$2" body="$3"
  gl_api POST "projects/:id/merge_requests/$iid/discussions/$did/notes" -f "body=$body" >/dev/null
}
gl_discussion_resolve() {
  local iid="$1" did="$2"
  gl_api PUT "projects/:id/merge_requests/$iid/discussions/$did" -F resolved=true >/dev/null
}

# ---------------------------------------------------------------------------
# Local clone management (one clone per project, reused across runs)
# ---------------------------------------------------------------------------
repo_dir() { echo "$GLT_WORKDIR/$PROJECT_SLUG"; }

repo_remote_url() {
  if [[ -n "$GLT_GIT_REMOTE" ]]; then echo "$GLT_GIT_REMOTE"; return; fi
  # Prefer ssh (works with the cron user's deploy key); fall back to https.
  gl_api GET "projects/:id" | jq -r '.ssh_url_to_repo // .http_url_to_repo'
}

ensure_repo() {          # clone once, then just fetch; prints nothing
  local dir; dir="$(repo_dir)"
  if [[ ! -d "$dir/.git" ]]; then
    local url; url="$(repo_remote_url)"
    log "cloning $url -> $dir"
    git clone --quiet "$url" "$dir" || die "clone failed"
    git -C "$dir" config user.name  "${GLT_GIT_USER_NAME:-gitlab-tools bot}"
    git -C "$dir" config user.email "${GLT_GIT_USER_EMAIL:-gitlab-tools@localhost}"
    git -C "$dir" config rerere.enabled true          # remember conflict resolutions
    # glab can act as the git credential helper for https remotes.
    if [[ "$url" == https://* ]]; then
      git -C "$dir" config credential.helper '!glab auth git-credential'
    fi
  fi
  git -C "$dir" fetch --quiet --prune origin || die "fetch failed"
  # Always start from a clean tree; previous crashed runs must not leak state.
  git -C "$dir" rebase --abort 2>/dev/null || true
  git -C "$dir" merge --abort  2>/dev/null || true
  git -C "$dir" reset --quiet --hard
  git -C "$dir" clean -qfd
}

checkout_branch() {      # checkout_branch <branch>  (tracking origin/<branch>, exact)
  local dir; dir="$(repo_dir)"
  git -C "$dir" checkout --quiet -B "$1" "origin/$1"
}

git_push() {             # git_push <branch> [--force-with-lease]
  local dir; dir="$(repo_dir)"
  if [[ "$GLT_DRY_RUN" = 1 ]]; then log "dry-run: git push origin $*"; return 0; fi
  git -C "$dir" push --quiet origin "$@"
}

run_verify() {           # run GLT_VERIFY_CMD inside the repo; 0 if unset or passing
  [[ -z "$GLT_VERIFY_CMD" ]] && return 0
  local dir; dir="$(repo_dir)"
  log "verify: $GLT_VERIFY_CMD"
  (cd "$dir" && timeout "${GLT_VERIFY_TIMEOUT:-1200}" bash -c "$GLT_VERIFY_CMD") >"$GLT_LOG_DIR/verify.last.log" 2>&1
}

# ---------------------------------------------------------------------------
# Unix mail
# ---------------------------------------------------------------------------
# send_mail <subject>   (body on stdin)
send_mail() {
  local subject="[gitlab-tools][$GLT_PROJECT] $1"
  local body; body="$(cat)"
  if [[ "$GLT_DRY_RUN" = 1 ]]; then
    log "dry-run: mail to $GLT_MAIL_TO: $subject"; printf '%s\n' "$body" >&2; return 0
  fi
  if [[ -n "$GLT_MAIL_CMD" ]]; then
    printf '%s\n' "$body" | eval "$GLT_MAIL_CMD \"\$subject\" \"\$GLT_MAIL_TO\""
  elif command -v mail >/dev/null 2>&1; then
    printf '%s\n' "$body" | mail -s "$subject" "$GLT_MAIL_TO"
  elif command -v mailx >/dev/null 2>&1; then
    printf '%s\n' "$body" | mailx -s "$subject" "$GLT_MAIL_TO"
  elif command -v sendmail >/dev/null 2>&1; then
    printf 'To: %s\nSubject: %s\nContent-Type: text/plain; charset=utf-8\n\n%s\n' \
      "$GLT_MAIL_TO" "$subject" "$body" | sendmail -t
  else
    local outbox="$STATE/outbox"; mkdir -p "$outbox"
    local f="$outbox/$(date +%Y%m%dT%H%M%S)-$RANDOM.eml"
    printf 'To: %s\nSubject: %s\n\n%s\n' "$GLT_MAIL_TO" "$subject" "$body" > "$f"
    warn "no mail/mailx/sendmail found; wrote $f"
  fi
}

# ---------------------------------------------------------------------------
# opencode (non-interactive)
# ---------------------------------------------------------------------------
# oc_run <agent> <workdir> <prompt-file> [extra args]
#   stdout : the model's final text (all text parts concatenated)
#   return : 0 on success, 1 on failure/timeout
#   side   : adds tokens to TOKENS_USED, writes raw events to $GLT_LOG_DIR
#
# Token-saving choices baked in here:
#   --title  : fixed title => opencode skips its separate title-generation call
#   --agent  : agents in opencode/opencode.json carry tiny prompts and only
#              the tools each job needs (fewer tool schemas in every request)
#   --format json : lets us parse text + token usage without a second call
oc_run() {
  local agent="$1" workdir="$2" prompt_file="$3"; shift 3
  local events="$GLT_LOG_DIR/opencode.$(date +%Y%m%dT%H%M%S).$agent.jsonl"
  [[ -f "$GLT_OPENCODE_CONFIG" ]] || die "opencode config not found: $GLT_OPENCODE_CONFIG"
  if [[ "$GLT_DRY_RUN" = 1 && "${GLT_DRY_RUN_ALLOW_LLM:-0}" != 1 ]]; then
    log "dry-run: would run opencode agent=$agent prompt=$prompt_file"
    return 1
  fi
  log "opencode run --agent $agent (prompt $(wc -c <"$prompt_file") bytes)"
  local rc=0
  (
    cd "$workdir" || exit 1
    export OPENCODE_CONFIG="$GLT_OPENCODE_CONFIG"
    export OPENCODE_DISABLE_AUTOUPDATE=1
    # Avoid the model fetching things over the network from a cron job.
    export OPENCODE_DISABLE_LSP_DOWNLOAD=1
    # The prompt is piped on stdin: no argv length limits, and `opencode run`
    # reads stdin whenever it is not a TTY. Never let it inherit cron's stdin -
    # it would block forever waiting for EOF.
    timeout "$GLT_OPENCODE_TIMEOUT" "$GLT_OPENCODE_BIN" run \
      --agent "$agent" --title "glt-$agent" --format json "$@" < "$prompt_file"
  ) > "$events" 2>"$events.stderr" || rc=$?
  if [[ $rc -eq 124 ]]; then warn "opencode timed out after ${GLT_OPENCODE_TIMEOUT}s (see $events.stderr)"; fi
  local used
  used="$(jq -rs '[.[] | select(.type=="step_finish") | .part.tokens.total // 0] | add // 0' "$events" 2>/dev/null || echo 0)"
  TOKENS_USED=$(( TOKENS_USED + ${used:-0} ))
  log "opencode finished rc=$rc tokens=$used (run total $TOKENS_USED)"
  if (( TOKENS_USED > GLT_MAX_TOKENS_PER_RUN )); then
    warn "token budget exceeded ($TOKENS_USED > $GLT_MAX_TOKENS_PER_RUN); later LLM work in this run is skipped"
    GLT_BUDGET_EXHAUSTED=1
  fi
  jq -rj 'select(.type=="text") | .part.text' "$events" 2>/dev/null
  echo
  [[ $rc -eq 0 ]]
}

budget_ok() { [[ "${GLT_BUDGET_EXHAUSTED:-0}" != 1 ]]; }

# Extract the first JSON object/array from model output (tolerates ``` fences).
extract_json() {
  python3 -c '
import json, re, sys
s = sys.stdin.read()
s = re.sub(r"^```(?:json)?\s*|\s*```$", "", s.strip(), flags=re.M)
# try the earliest opener first so an outer array wins over an inner object
starts = sorted((s.find(o), o, c) for o, c in (("[", "]"), ("{", "}")) if s.find(o) != -1)
for i, opener, closer in starts:
    while i != -1:
        j = s.rfind(closer)
        while j > i:
            try:
                json.loads(s[i:j+1]); print(s[i:j+1]); sys.exit(0)
            except Exception:
                j = s.rfind(closer, i, j)
        i = s.find(opener, i + 1)
sys.exit(1)'
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------
truncate_text() {        # truncate_text <max-bytes>  (stdin -> stdout)
  head -c "$1"
}
mr_url() { gl_api GET "projects/:id/merge_requests/$1" | jq -r .web_url; }
strip_ansi() { sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\r$//'; }
# Lines of a file around a line number, with numbers: code_context <file> <line> [radius]
code_context() {
  local file="$1" line="$2" r="${3:-8}" dir; dir="$(repo_dir)"
  [[ -z "$line" || "$line" = null || ! -f "$dir/$file" ]] && return 0
  local from=$(( line - r )); (( from < 1 )) && from=1
  sed -n "${from},$(( line + r ))p" "$dir/$file" | nl -ba -v "$from" -w 4 -s ': '
}
# Collect open MRs we own as compact JSON lines: iid src tgt sha title draft fork
mr_candidates() {        # mr_candidates [iid...]  -> one JSON object per line
  if (( $# )); then
    local iid; for iid in "$@"; do gl_mr "$iid" | jq -c '{iid, source_branch, target_branch, sha, title, draft, web_url, author: .author.username, labels, fork: (.source_project_id != .target_project_id), head_pipeline}'; done
  else
    gl_mr_list | jq -c --argjson skipdraft "$GLT_SKIP_DRAFTS" '
      .[] | select(.state=="opened")
      | select(($skipdraft==1 and (.draft or .work_in_progress)) | not)
      | {iid, source_branch, target_branch, sha, title, draft, web_url, author: .author.username, labels, fork: (.source_project_id != .target_project_id), head_pipeline}'
  fi
}
has_label() { jq -e --arg l "$2" '.labels // [] | index($l) != null' <<<"$1" >/dev/null; }
