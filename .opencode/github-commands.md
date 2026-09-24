# `/oc` GitHub PR commands

These instructions apply when a user message is posted on a GitHub PR via the opencode
GitHub Action and begins with `/oc` (or `/opencode`). The message usually carries a
`<pull_request>` context block (title, body, changed files, comments, reviews) — read it
carefully before answering.

## Absolute rule: never emit `@path` tokens in anything you post

**The action posts your reply text verbatim — it does NOT expand files.** A line like
`@/tmp/opencode/summary.md` (or any `@...` path token) in a finding body, a thread reply,
or the final summary is posted literally as the comment body, leaking a runner path into a
public comment.

- **Never** write `@/tmp/...`, `@./...`, or any `@<file>` shorthand in text that will be
  posted. A body that references a file is a bug, not a shortcut.
- If you draft content in a temp file, **read it back and inline the full contents** before
  posting. When a reply is long, paste it — do not reference it.
- The `@file` form is only ever valid as a **`-F` raw-field** argument to the `gh` CLI
  (`-F body=@file` reads the file contents), and only when you invoke `gh` directly in a
  shell. Lowercase `-f` never expands it: `-f body=@file` posts the literal `@file`
  string. When in doubt pass real content instead (e.g. `-f body="$(cat file)"`).
- **Mandatory self-check before finishing:** grep every body you are about to post for
  `@/` and `/tmp/`. If anything matches, fix it. The workflow fails the run when a posted
  comment leaks a path token, so a leak shows up as a red check — but never count on that;
  inline content from the start.

## Model routing

Unless the caller pins a `model`, the workflow probes a chain of candidate models per
command type and selects the first that answers a minimal request. `/oc review` (and
automatic PR-opened reviews) use the review chain; everything else uses the fix chain.
Chains are ordered, comma-separated entries: `cf:<id>` is probed through the Cloudflare
Workers AI OpenAI-compatible endpoint (behind `CLOUDFLARE_ACCOUNT_ID` /
`CLOUDFLARE_API_TOKEN`), `zen:<id>` through the opencode.ai Zen gateway (behind
`OPENCODE_API_KEY`), and a bare `provider/model` is selected without probing. The chosen
model arrives via `OPENCODE_CONFIG_CONTENT`; no `variant` (reasoning-effort) is applied
unless the caller sets the `variant` input.

## Using context7

The `context7` MCP server (remote, wired via the action's OpenCode config) is available to
look up **current, version-accurate library/framework documentation** — handy because the
agent's training data can go stale. Use its `resolve-library-id` and `query-docs` tools.

**When to use it** (both commands):

- **Authoring or changing API calls** — before writing code that calls a library, framework,
  or SDK, look up the exact current API so you don't invent a wrong signature or import
  (e.g. React 19 hooks, Express routes, Vite config).
- **Resolving an API-relevant review finding** — when `/oc fix` addresses a comment about a
  library usage, confirm the expected current behavior/API from docs rather than guessing.
- **Copy-pasted code that may be outdated** — verify before trusting it.

**When NOT to use it:**

- For pure project-internal logic, the diff, or code you're already certain about — don't
  spend tool calls (and context) re-confirming things you know.
- For general web/non-library lookups — context7 is a documentation index, not a search
  engine; prefer the model's own knowledge for non-API questions.

**How to use it:**

1. `resolve-library-id` (pass the library name from the message, e.g. "Express", "React").
2. `query-docs` with the returned library ID and a focused, single-concept question.
3. Use `use context7` in tool choice; keep queries narrow so results stay small and relevant.

## `/oc review`

A review also runs **automatically when a pull request is first opened** (the workflow's
`pull_request: [opened]` trigger), in addition to on-demand. It does NOT re-run on later
commits to the same PR.

When a user message is exactly `/oc review` or begins with `/oc review`, treat it as a
request to review the current pull request. Extra text after the shortcut, e.g.
`/oc review focus on security`, scopes the review to those concerns. The same posting
behavior below applies whether the review is triggered by `/oc review` or by PR creation.

### Posting behavior

**One comment per actionable finding.** Do NOT write one big review. Instead:

1. Identify the actionable findings. An actionable finding is one where you can point at a
   concrete problem in the code and, when feasible, propose a specific change.
2. Post each actionable finding as its **own resolvable review thread** via the `gh` CLI
   (preinstalled in GitHub Actions; the `GITHUB_TOKEN` env var is available, no login
   needed). Fall back down this ladder until the finding is posted:

   **Hard rule:** one `gh` comment per actionable finding, at the highest resolution
   available. Never put more than one finding in a single comment, and never restate a
   finding's body in the final summary — the summary is only an index of links.

   > **CRITICAL — the comment body must be the finding CONTENT, never a file path.**
   > Do NOT post the literal string `@…/finding.md` (or any `@path` token) as the body.
   > The `@file` shorthand only works when the `gh` CLI itself expands it; opencode's
   > review posting path does not, so an `@path` value leaks the path into the comment.
   > Always ground the comment in the actual finding text.

   The `gh` calls you make run under the `GITHUB_TOKEN`, so the review threads you
   create appear as `github-actions[bot]`. Your final reply (step 3) is posted by
   opencode itself: as `opencode-agent[bot]` under the default OIDC app-token flow, or
   as `github-actions[bot]` when the action runs with `use-github-token: true`.

   a. **Inline line comment** (preferred) — pins the finding to a line in the PR diff and
   creates a resolvable thread. Use the PR head SHA (`Head: { Sha: ... }` in the
   `<pull_request>` context) as `commit_id`, plus the file and line the finding is
   about. Use `gh` CLI with the `@` form ONLY when you are directly invoking `gh` in a
   shell. The `@` must immediately follow `=` on a **`-F` raw-field** flag, with no
   surrounding quotes/spaces, for gh to read the file; lowercase `-f` posts the literal
   `@path` string:

   ```bash
   gh api repos/{owner}/{repo}/pulls/{pr_number}/comments \
     -F body=@finding.md \
     -f path="src/example.ts" \
     -F line=42 \
     -f commit_id="$HEAD_SHA"
   ```

   If you are posting through opencode's built-in review tooling instead, READ the
   `finding.md` file and pass its full contents as the `body` value — never the path.

   **Never** pass `@path` as the body through opencode's built-in tooling.

   For a finding spanning a line range, add `-F start_line=<first line>` (and, for a
   deletion, `-f start_side=LEFT`).

   b. **File-level comment** — if the exact line is unknown, or the line-comment call
   returns a 422, post a **file-level** review comment (`subject_type=file`). This still
   creates a resolvable thread and is the recommended fallback whenever you know the file
   but not the precise line (same `body` rule applies):

   ```bash
   gh api repos/{owner}/{repo}/pulls/{pr_number}/comments \
     -F body=@finding.md \
     -f path="src/example.ts" \
     -f subject_type=file
   ```

   c. **Issue comment** (last resort, non-resolvable) — only if the file is not part of
   the PR diff at all. Post **one issue comment per finding**:

   ```bash
   gh api repos/{owner}/{repo}/issues/{pr_number}/comments -F body=@finding.md
   ```

   Derive `owner`/`repo` from `baseRepository.nameWithOwner` in the `<pull_request>`
   context (split on `/`), `pr_number` from `Number:`, and `HEAD_SHA` from
   `Head: { Sha: ... }`. Writing the finding body to a temp file (`finding.md`) is a useful
   drafting aid, but the posted `body` must be that file's **contents**, not its name. Post
   threads one at a time — this endpoint is secondary-rate-limited if you post too
   fast — and keep a list of the posted comment IDs/URLs and of which findings fell back to
   an issue comment. If a `gh` call fails at every level for a finding, move on to
   the next finding's comment; for any finding you truly cannot post, reference it (not
   its body) in the summary's "Out of diff" section.

3. **Your final reply text** (what the action posts as the single `opencode-agent[bot]`
   summary comment) must be a **short summary index only — it must NOT contain finding
   bodies**. It is: overall assessment; one line per threaded finding with its file:line,
   severity, and a link to that finding's comment (both endpoint responses include the
   `html_url`); and an **"Out of diff"** section listing only the _links_ to any fallback
   issue comments (from step 2c) plus any finding with no diff location (e.g. missing
   tests, missing docs, cross-file concerns), each with severity and the file(s)/line(s) it
   covers. All finding detail lives in the per-finding comments posted in step 2.
4. Only trivial, non-actionable nits may be grouped — at most one small extra comment — and
   never mixed with actionable findings. Every actionable finding is its own thread.

### Committing behavior — suggestions only

You are reviewing, not editing:

- **Do NOT modify any files and do NOT leave the working tree dirty.** The action auto-commits
  and pushes any uncommitted changes to the PR branch — that is not wanted here.
- Include a **committable suggestion** in each finding comment when it is feasible to write
  one for that specific finding. Wrap the exact replacement in a GitHub `suggestion`
  fenced block so GitHub renders a one-click **Commit suggestion** button right in the
  comment:

  ````text
  ```suggestion
  <exact replacement lines — must match the current file content>
  ```
  ````

  Use one contiguous block per finding, matching the existing lines it replaces; GitHub
  applies it to the file on commit. If a finding does not have a cut-and-dried fix — no
  contiguous single-file replacement — say so and describe the change needed instead of
  inventing code.

### Finding comment format

Each finding comment should contain:

1. **Severity** — `high` / `medium` / `low` (or `critical`).
2. **Location** — `file:line` (or a line range).
3. **Problem** — why it is wrong, grounded in the actual code. Keep it to a few
   sentences (~80 words target): state the defect and the evidence, do not
   narrate your verification process.
4. **Suggested fix** — a GitHub `suggestion` fenced block (see "Committing behavior")
   when the fix is a contiguous replacement of the anchored lines, otherwise a
   one-sentence description of the change needed. Anchor the comment's line
   range to cover exactly the lines a `suggestion` block rewrites so the thread
   is one-click committable.

### Review scope

Look for: correctness bugs, security issues (injection, secret handling, authorization),
performance, maintainability, and test coverage gaps. Ground every finding in the actual diff
and files. Do not invent issues; verify against the code. If there are no actionable findings,
just say so in the summary comment and do not post finding comments.

## `/oc fix` and `/oc autopilot`

When a user message begins with `/oc fix` or `/oc autopilot`, **load and follow the
`autopilot` skill** — it defines one disciplined merge-readiness pass for this pull
request: merge conflicts first, then unresolved review threads and other feedback, then
failing CI, in that order.

- `/oc fix <scope>` narrows the pass to the named feedback (e.g. "fix the comment about
  X"); a bare `/oc fix` or `/oc fix all` runs the full pass.
- `/oc autopilot` always means the full unconditional pass, same as `prompt: /autopilot`
  on `workflow_dispatch`.

The action auto-commits and pushes working-tree changes and posts your final reply as
the summary comment — the skill's Reporting section defines what that summary must
cover. Escalation is by summary comment, not by stopping mid-run: surface security,
auth, billing, migration, and concurrency questions explicitly instead of guessing.
