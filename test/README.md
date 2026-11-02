# Tests

* `run-tests.sh` - end-to-end, no network, no tokens. `test/mocks/bin` shadows `glab`, `opencode`
  and `mail`; a bare repository in a temp dir plays GitLab's git remote. Keep the temp dir with
  `GLT_TEST_KEEP=1`.
  * mock `glab api GET` answers from fixture files named after the path
    (`merge_requests_1_discussions.json`, `jobs_7_trace.txt`, `project.json`, ...); writes are logged
    to `$GLT_TEST_CALLS` and answered with a stub.
  * mock `opencode run` records the prompt in `$GLT_TEST_OC_DIR/<agent>.prompt`, runs
    `<agent>.sh` in the checkout if present (to simulate edits) and prints `<agent>.response` as a
    `--format json` text event plus a `step_finish` with token counts.
* `mock-llm/smoke.sh` - the real `opencode` binary with `opencode/opencode.json` and
  `mock-llm/mock_llm.py`, a scripted OpenAI-compatible `/v1/chat/completions` server. Use it to
  rehearse prompts/permissions without spending tokens: put the turns you want the "model" to
  produce in the script JSON (`{"text": ...}` or `{"tool": "bash", "args": {...}}`).
