# opencode-action

Run an [OpenCode](https://opencode.ai/) agent from GitHub Actions, including issue and pull request comments, pull request reviews, and manually dispatched tasks.

[![CI](https://github.com/tonythethompson/opencode-action/actions/workflows/ci.yml/badge.svg)](https://github.com/tonythethompson/opencode-action/actions/workflows/ci.yml)

This is a fork of [dceoy/opencode-action](https://github.com/dceoy/opencode-action) kept in sync with upstream. Everything upstream provides still works; this fork adds resilience features on top:

- **Model probe chains** — `model` is optional. When empty, `models-review`/`models-fix` fallback chains are probed in order (`cf:` Cloudflare Workers AI, `zen:` OpenCode Zen, or bare `provider/model` unprobed) and the first reachable model wins. See [Model probe chains](#model-probe-chains).
- **Verified install** — the OpenCode release asset's sha256 digest is checked before extraction instead of piping the installer to a shell.
- **Deadline, retry, and salvage** — the agent budget is anchored to job start; a failed run salvages local-only agent commits onto the updated remote and retries once within the same budget.
- **Comment leak guard** — `guard-path-leaks` snapshots PR comments and fails the job if a posted comment leaks `@/` or `/tmp/` path tokens.
- **`setup-commands` input** — the reusable workflows run caller-supplied shell commands after checkout so the agent has the repo's toolchain.
- **Bundled GitHub runbook** — `.opencode/github-commands.md` documents review/thread posting, thread resolution, and the `@path` rules, and is wired through config `instructions` so it reaches the agent (including in review-only isolation).

## Quick start

### 1. Add a provider secret

In **Settings → Secrets and variables → Actions**, add the API key for your model provider. The example below uses `OPENCODE_API_KEY`.

### 2. Add the workflow

Create `.github/workflows/opencode.yml`:

<!-- prettier-ignore -->
```yaml
---
name: OpenCode
on:
  issue_comment:
    types: [created]
  pull_request_review_comment:
    types: [created]
permissions:
  contents: write
  issues: write
  pull-requests: write
  id-token: write
jobs:
  opencode:
    if: contains(github.event.comment.body, '/oc') || contains(github.event.comment.body, '/opencode')
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repository
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1  # v7.0.1
        with:
          persist-credentials: false
      - name: Run OpenCode
        uses: tonythethompson/opencode-action@95e649111ed92c7885c2aef3f83087643637d732  # v0.8.2
        env:
          OPENCODE_API_KEY: ${{ secrets.OPENCODE_API_KEY }}
          GITHUB_TOKEN: ${{ github.token }}
        with:
          model: opencode-go/kimi-k3
```

### 3. Comment on an issue or pull request

```text
/opencode explain this issue
```

The shorter `/oc` trigger also works:

```text
/oc fix this
```

The default setup exchanges the workflow OIDC token for an OpenCode GitHub App token, which requires `id-token: write`.

## Reusable workflows

For smaller caller workflows, this repository provides reusable workflows for OpenCode tasks and pull request reviews:

| Workflow                                                       | Purpose                                                                 |
| -------------------------------------------------------------- | ----------------------------------------------------------------------- |
| [`opencode-bot.yml`](.github/workflows/opencode-bot.yml)       | Run OpenCode from trusted comments, manual dispatch, or a fixed prompt. |
| [`opencode-review.yml`](.github/workflows/opencode-review.yml) | Run the bundled `/review-pr` flow for `pull_request` events.            |

See [Reusable workflows](docs/reusable-workflows.md) for caller examples, inputs, secrets, and permission requirements.

## Models and secrets

Set `model` to a `provider/model` value and pass the corresponding API key:

| Provider        | Example model                | Secret               |
| --------------- | ---------------------------- | -------------------- |
| OpenCode        | `opencode-go/kimi-k3`        | `OPENCODE_API_KEY`   |
| OpenRouter      | `openrouter/openrouter/free` | `OPENROUTER_API_KEY` |
| Anthropic       | `anthropic/claude-opus-5`    | `ANTHROPIC_API_KEY`  |
| OpenAI          | `openai/gpt-5.6-sol`         | `OPENAI_API_KEY`     |
| Custom provider | `myprovider/my-model`        | Provider-specific    |

The provider account must have sufficient credits or quota. For providers not built into OpenCode, see [Custom providers](docs/custom-providers.md).

### Model probe chains

When `model` is left empty, the action probes a comma-separated fallback chain and selects the first reachable entry. `models-review` applies to review runs (`pull_request` triggers, `/review-pr`, and `/oc review`); `models-fix` applies to everything else. Entries are:

- `cf:<model>` — probed through the Cloudflare Workers AI OpenAI-compatible endpoint; requires `CLOUDFLARE_ACCOUNT_ID` and `CLOUDFLARE_API_TOKEN`. Selected as `cloudflare-workers-ai/<model>` and registered on the built-in provider.
- `zen:<model>` — probed through the opencode.ai Zen gateway; requires `OPENCODE_API_KEY`. Selected as `opencode/<model>`.
- `<provider>/<model>` — selected without probing; the caller supplies the provider's credentials.

The job fails if no chain entry answers, so pin `model` when you need a guaranteed selection.

## Sakura AI Engine model synchronization

The optional [Sakura model synchronization workflow](.github/workflows/sync-sakura-models.yml) discovers chat-capable Sakura AI Engine models and opens or updates a pull request when the catalog changes. Configure the `SAKURA_AI_ENGINE_API_KEY` repository secret before enabling it.

The workflow uses the repository-provided `GITHUB_TOKEN` with `contents: write` and `pull-requests: write`; no additional GitHub token secret is required. GitHub does not create new workflow runs for events triggered by `GITHUB_TOKEN`, so pull requests created by this workflow do not automatically trigger `pull_request` workflows. See [GitHub's `GITHUB_TOKEN` documentation](https://docs.github.com/en/actions/concepts/security/github_token).

## Inputs

| Input                 | Default                   | Description                                                                                                                                                             |
| --------------------- | ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `model`               | Probe the chains          | Model in `provider/model` format. Empty probes `models-review`/`models-fix`.                                                                                            |
| `models-review`       | Cloudflare then Zen chain | Comma-separated probe chain for review runs. Entries: `cf:<model>`, `zen:<model>`, or bare `provider/model`.                                                            |
| `models-fix`          | Cloudflare then Zen chain | Comma-separated probe chain for non-review runs. Same entry syntax as `models-review`.                                                                                  |
| `guard-path-leaks`    | `true`                    | Fail the job when a comment posted by this run leaks a `@/` or `/tmp/` path token.                                                                                      |
| `job-started-at`      | Run step start            | Epoch the job started; anchors the shared agent deadline so the single retry cannot overrun the budget.                                                                 |
| `agent`               | `build`                   | Primary agent. A slash command can override it.                                                                                                                         |
| `prompt`              | Event comment             | Fixed prompt to use instead of the triggering comment.                                                                                                                  |
| `mentions`            | `/opencode,/oc`           | Comma-separated trigger phrases.                                                                                                                                        |
| `variant`             | -                         | Provider-specific reasoning effort; leave empty unless supported. See [Custom providers](docs/custom-providers.md#variants-for-custom-providers).                       |
| `share`               | `false`                   | Share the OpenCode session.                                                                                                                                             |
| `use-github-token`    | `false`                   | Use the workflow token instead of the default App-token flow.                                                                                                           |
| `opencode-version`    | `latest`                  | OpenCode version to install. `/review-pr` requires 1.2.14+; the bundled Sakura provider's `chunkTimeout` needs 1.2.25+ (older pins fall back to the request `timeout`). |
| `use-bundled-toolkit` | `true`                    | Use the bundled agents, commands, skills, and configuration.                                                                                                            |
| `timeout-minutes`     | `60`                      | Stop OpenCode after this many minutes.                                                                                                                                  |
| `oidc-base-url`       | `https://api.opencode.ai` | OIDC exchange URL for a custom GitHub App installation.                                                                                                                 |

Direct `workflow_dispatch` uses the same inputs as `workflow_call`; a non-empty `prompt` is required to run the job, and an empty `model` triggers the probe chains.

When `use-github-token: true`, keep `GITHUB_TOKEN` in `env` and grant only the permissions needed for the task.

Outputs are `opencode-version`, `model`, and `cache-hit`. `cache-hit` is empty on review-only runs (`prompt: /review-pr`), which always skip the cache and install fresh. The installed binary is verified against the sha256 digest published on the OpenCode release, and a failed run retries once after attempting to salvage locally committed agent work onto the updated remote.

## Pull request reviews

Set `prompt: /review-pr` to run the bundled read-only review through a dedicated permission-constrained primary agent. The command loads the internal `pr-review` skill, which builds a change/risk map, dispatches fresh read-only child sessions, independently validates candidate findings, and posts confirmed findings inline when they can be anchored to changed lines. Use `/review-pr` rather than loading `pr-review` directly when the enforced read-only boundary is required.

An unscoped review creates a small set of dynamic, risk-driven discovery tasks instead of routing to fixed specialist agents. Explicit aspects such as `security`, `tests`, `docs`, `performance`, or `simplify` constrain the selected review lenses. Discovery and validation run in separate fresh child sessions; the current OpenCode v1-compatible implementation uses one hidden `review-worker` definition for those sessions.

See [Pull request reviews](docs/pull-request-reviews.md) for setup, supported review aspects, submission behavior, and security guarantees.
