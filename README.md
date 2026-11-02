# gitlab-tools

Cron-driven automation for GitLab merge requests built from three parts:

* **`glab`** (GitLab CLI) + `git` + `jq` for everything deterministic,
* **`opencode run`** (non-interactive) only when a decision or an edit genuinely needs a model,
* **Unix mail** for everything that needs a human.

The guiding rule is *tokens are the expensive resource*: each script does as much as it can with
zero LLM calls, makes at most one cheap classification call per unit of work, and only then
spends on an editing agent with a tightly scoped prompt and tool set.

```
bin/glt-mr-rebase     keep MRs rebased on main; plan/resolve conflicts
bin/glt-mr-comments   act on review comments: fix / escalate by mail / draft a reply
bin/glt-ci-triage     retry flaky jobs for free, summarise real failures, optional auto-fix
bin/glt-issue-to-mr   labelled issue -> implemented draft MR
bin/glt-mr-digest     daily "what needs me" email (0 tokens)
bin/glt-reply         post a reply from the e-mail into an MR thread
bin/glt-doctor        check the host has everything the cron jobs need
lib/common.sh         shared: glab/git/mail/opencode wrappers, locking, state, token budget
opencode/             recommended opencode.json + agent prompts
config/               env.example, flaky-patterns.txt
cron/crontab.example
test/                 mocks + end-to-end tests (no network, no tokens)
```

## Install

```bash
git clone <this repo> ~/gitlab-tools
sudo apt install jq git util-linux mailutils          # flock, mail
# glab: https://gitlab.com/gitlab-org/cli/-/releases   (or brew/apt)
npm install -g opencode-ai                              # opencode

mkdir -p ~/.config/gitlab-tools && cp ~/gitlab-tools/config/env.example ~/.config/gitlab-tools/env
chmod 600 ~/.config/gitlab-tools/env && $EDITOR ~/.config/gitlab-tools/env   # GLT_PROJECT, GITLAB_TOKEN, ...
glab auth login            # or just GITLAB_TOKEN in the env file (api + write_repository scopes)
opencode providers         # store the model provider key, or put ANTHROPIC_API_KEY in the env file
~/gitlab-tools/bin/glt-doctor
```

Every script reads `~/.config/gitlab-tools/env` (override with `GLT_CONFIG`), accepts `--dry-run`
(no pushes, no API writes, no mail, no LLM) and `-v`, and takes a per-project `flock` so overlapping
cron ticks are harmless. State lives in `~/.local/state/gitlab-tools/<project>/` (what was already
handled, token logs, raw opencode event logs, and a mail `outbox/` if no MTA exists).

Which MRs are "ours" is `GLT_MR_LIST_ARGS` (default `--author=@me`), any `glab mr list` filter works,
e.g. `--label=bot-managed`. MRs from forks are always skipped (nothing can be pushed there).

Set `GLT_VERIFY_CMD` (e.g. `make test` or `npm test`). Nothing is ever pushed unless it passes, and
**the scripts run it, not the model**, which is both cheaper and deterministic.

## Workflow 1 - automated rebasing (`glt-mr-rebase`)

```
*/15 * * * *  glt-mr-rebase          # cron
glt-mr-rebase --mr 42 --mode resolve # one MR, override the conflict mode
```

1. `git fetch`; for each MR, `git rev-list --count origin/src..origin/target`. Zero means nothing to
   do. **No API calls beyond the MR list, no tokens.**
2. Local `git rebase origin/<target>`. Clean: run `GLT_VERIFY_CMD`, `push --force-with-lease`
   (pinned to the sha we started from), post a note on the MR. **Still no tokens.**
3. Conflicts, by `GLT_REBASE_CONFLICT_MODE` / `--mode`:
   * `mail` - abort, e-mail the `zdiff3` hunks and the reproduce commands.
   * `plan` (default) - the read-only `glt-planner` agent writes a per-file resolution plan;
     e-mail it with the hunks. The rebase is aborted; your branch is untouched.
   * `resolve` - the `glt-resolver` agent (edit tools, **no shell**) edits only the conflicted files.
     The script checks no markers remain, stages, `rebase --continue`s (looping for later commits,
     max `GLT_MAX_CONFLICT_ROUNDS`), verifies, force-pushes with lease, comments on the MR with the
     agent's per-file notes, and e-mails you a "please review" summary. Any failure aborts and
     falls back to the `mail` behaviour.
4. Each `(MR, source sha, target sha)` conflict is attempted once; it is not retried until either
   branch moves, so a hard conflict does not burn tokens every 15 minutes. `rerere` is enabled in
   the clone so a resolution you make by hand is reused next time. Label an MR
   `no-auto-rebase` to exclude it.

## Workflow 2 - review comments (`glt-mr-comments`)

```
*/10 * * * *  glt-mr-comments
```

For every unresolved discussion whose **latest** note is not ours (so a thread is only revisited
when the reviewer writes again):

| step | cost | what |
|------|------|------|
| GitLab `suggestion` blocks | 0 | applied through `PUT /suggestions/:id/apply` |
| `LGTM` / `+1` / quick actions (`/label`) | 0 | ignored |
| everything else, batched **per MR** | 1 small-model call, no tools | `glt-classifier` returns JSON: `minor_fix` / `substantial` / `question` / `no_action` with a one-line summary, a draft reply for questions, a "what it would involve" for substantial ones. The prompt includes +/-8 lines of code around each comment, pulled locally with `sed`, so the small model can judge without tools. |
| `minor_fix` | 1 `glt-fixer` run | edit tools + read-only git. Script checks the diff is small (`GLT_MAX_FILES_PER_FIX`), runs `GLT_VERIFY_CMD`, commits (`Addresses review comment by @x on !N`), pushes once per MR, replies "Addressed in <sha>" in the thread. The agent can answer `ESCALATE:` instead of editing; that becomes an e-mail. |
| `substantial` | 0 | e-mail: file/line, the comment, what the change involves |
| `question` | 0 | e-mail: the question, the drafted reply, and a ready-to-paste `glt-reply <iid> <discussion> <<'EOF' ... EOF` command |

One e-mail per MR per run with three sections: needs your decision / questions awaiting reply /
auto-fixed (please review). `GLT_COMMENTS_HEURISTIC_ONLY=1` disables the model entirely
(`?` -> question, else substantial). `GLT_AUTO_RESOLVE=1` resolves threads after a fix (default
is to let the reviewer do it). Threads are tracked by `(discussion id, latest note id)`.

## Three more workflows

### 3. CI failure triage (`glt-ci-triage`)
Failed head pipeline on one of our MRs -> fetch only the failed jobs' log **tails** (ANSI stripped).
Jobs whose `failure_reason` is infrastructure, or whose log matches `config/flaky-patterns.txt`, are
**retried via the API, zero tokens** (max `GLT_CI_MAX_RETRIES` per job name). Real failures get one
`glt-summarizer` call (small model, no tools) producing `category / root_cause / fix_suggestion /
auto_fixable`, e-mailed with the raw tails. With `GLT_CI_AUTOFIX=1`, `lint`/`build` failures judged
auto-fixable are handed to `glt-fixer` (verify, commit, push with lease). Each pipeline id is
triaged once.

### 4. Issue -> draft MR (`glt-issue-to-mr`)
Issues labelled `opencode` (the label is the spend gate: a human chooses what costs tokens) are
implemented by `glt-implementer` on `glt/issue-<iid>` off the default branch, verified, pushed, and
opened as a Draft MR with `Closes #<iid>` and the agent's summary. The label is swapped for
`opencode::mr-created` or `opencode::needs-human` (when the agent escalates, changes nothing, or
verification fails) so the board shows status and nothing is attempted twice.
`GLT_ISSUE_MAX_PER_RUN` caps spend per tick.

### 5. Daily digest (`glt-mr-digest`)
Zero-token morning e-mail: MRs waiting for my review, my MRs ready to merge (with the
`glab mr merge` command), blocked ones (conflicts / failed pipeline / unresolved threads), stale
ones. `GLT_DIGEST_LLM=1` prepends a 5-bullet "do first" list from the small model.

Other cheap ideas on the same skeleton: release-notes draft from MRs merged since the last tag
(one summarizer call per release), nightly "approve + auto-merge dependency-bot MRs whose pipeline
is green" (0 tokens, `glab mr approve` + `glab mr merge --auto-merge`), auto-labelling new MRs
from their changed paths (0 tokens), and a weekly "unanswered questions on my MRs" reminder.

## opencode configuration (`opencode/opencode.json`)

The scripts never touch the target repository's own opencode config: they point `OPENCODE_CONFIG`
at this file, so every job runs with the same agents regardless of which project it checks out.
Set `GLT_OPENCODE_CONFIG` to use your own copy. Model ids: run `opencode models` to see what your
provider exposes and edit `model` / `small_model` / per-agent `model` accordingly.

What is in it and why:

* **Global `permission`: `edit: deny`, `bash: deny`, `webfetch: deny`.** Default closed; agents opt in.
* **`share: disabled`, `autoupdate: false`** - cron jobs must not upload sessions or self-update.
* **One primary agent per job**, each with the *smallest* tool set, because every enabled tool's
  schema is sent on every request:
  * `glt-classifier`, `glt-summarizer` - `small_model`, temperature 0, **no tools at all**. They
    return JSON; the script does the acting.
  * `glt-planner` - read-only (`read`, `glob`, `grep`), no bash.
  * `glt-resolver` - `read`/`glob`/`grep`/`edit`/`write`, **no bash**: staging, `rebase --continue`
    and verification are the script's job, so the model cannot run `git` at all.
  * `glt-fixer`, `glt-implementer` - edit tools plus bash restricted to read-only git. The bash
    rule map is `{"*": "deny", "git diff*": "allow", "git status*": "allow", ...}`: the catch-all
    comes **first**; in the opencode build we tested, a trailing `"*": "deny"` removes the bash
    tool entirely while a leading one keeps it with only the listed patterns allowed.
  * `glt-reviewer` - an example `mode: subagent` (read-only, small model) you can let the
    implementer call by enabling the `task` tool on it. It is off by default: a subagent is a
    second context window, i.e. a second bill.
* **`task`, `todowrite`, `webfetch`, `websearch`, `skill`, `lsp` are disabled on every agent.**
* **System prompts are files** (`prompt: "{file:./prompts/x.md}"`), 10-25 lines each. The task
  prompt the script builds carries only the relevant comment/hunk/log tail, capped
  (`GLT_NOTE_MAX_CHARS`, `GLT_MAX_CONTEXT_BYTES`, `GLT_CI_LOG_TAIL`).

Facts about non-interactive mode that shaped the scripts (verified against opencode 1.19.5 with a
local mock provider, see `test/mock-llm/`):

* `opencode run` reads the prompt from **stdin when stdin is not a TTY**; the scripts pipe the
  prompt file in. If a cron job lets it inherit an open stdin it blocks forever.
* `--title <fixed>` skips the separate title-generation LLM call (about 2k tokens per run otherwise).
* `--format json` prints one event per line; the scripts take `type=="text"` parts as the answer and
  sum `step_finish.part.tokens.total` into a per-run budget (`GLT_MAX_TOKENS_PER_RUN`; further LLM
  work in the run is skipped once exceeded).
* A permission set to **`ask` is auto-rejected** in `run` mode and the turn ends there; `deny`
  removes the tool from the model's list. Configure every permission explicitly as `allow` or
  `deny`, and do not use `--auto` (it turns every `ask` into `allow`).
* Env for cron: `OPENCODE_CONFIG`, `OPENCODE_DISABLE_AUTOUPDATE=1`, `OPENCODE_DISABLE_LSP_DOWNLOAD=1`
  are set by `lib/common.sh`; provider credentials come from `opencode providers` (stored under the
  cron user's `$HOME`) or `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` in the env file. opencode also
  loads `AGENTS.md`/`CLAUDE.md` from the checked-out project; keep those short or set
  `OPENCODE_DISABLE_CLAUDE_CODE_PROMPT=1`.

## Testing

```bash
test/run-tests.sh          # mocks glab/opencode/mail; real git against a local bare origin
test/mock-llm/smoke.sh     # REAL opencode binary + shipped config + a mock OpenAI-compatible server
```

`run-tests.sh` covers: clean rebase (no model), conflict -> plan mail, conflict -> resolve + push,
resolve + failing verify (nothing pushed), comment handling (suggestion applied for free, LGTM and
resolved/system/self-answered threads filtered, one classifier call, fix committed + reply posted,
question + substantial mailed, idempotence, escalation), CI triage (flaky retry, ANSI stripping,
once per pipeline), issue -> draft MR, digest, and `--dry-run`.

`smoke.sh` starts `test/mock-llm/mock_llm.py` (a scripted `/v1/chat/completions` server), overlays
a `mock` provider onto `opencode/opencode.json`, and checks every agent loads, prompt files reach
the model as the system prompt, the classifier sends no tools, the resolver has no bash, exactly
one LLM call is made, and `--format json` parses. The same server is a cheap way to rehearse a new
prompt or permission rule before spending real tokens: edit the script file it serves.
