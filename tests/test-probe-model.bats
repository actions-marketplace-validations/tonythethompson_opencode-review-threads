#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  probe_script="${repo_root}/scripts/probe-model.sh"
  fake_action="${BATS_TEST_TMPDIR}/action"
  fake_workspace="${BATS_TEST_TMPDIR}/workspace"
  mkdir -p "${fake_action}/.opencode" "${fake_workspace}/.opencode"
  touch "${fake_action}/.opencode/github-commands.md"
}

@test "review detection covers pull_request events, /review-pr commands, and review prompts" {
  run bash -euo pipefail -c '
    source "$1"
    opencode_probe_is_review "" pull_request
  ' _ "${probe_script}"
  [ "${status}" -eq 0 ]

  for prompt in "/review-pr" "/review-pr security" "review" "review focus on auth"; do
    run bash -euo pipefail -c '
      source "$1"
      opencode_probe_is_review "$2" issue_comment
    ' _ "${probe_script}" "${prompt}"
    [ "${status}" -eq 0 ]
  done

  for prompt in "fix" "preview this" "reviewable" ""; do
    run bash -euo pipefail -c '
      source "$1"
      opencode_probe_is_review "$2" issue_comment
    ' _ "${probe_script}" "${prompt}"
    [ "${status}" -ne 0 ]
  done
}

@test "custom model collection deduplicates cf: and gh: entries across both chains" {
  run bash -euo pipefail -c '
    source "$1"
    opencode_probe_custom_models "cf:@cf/a,zen:b, cf:@cf/c ,other/x,cf:@cf/a,gh:openai/gpt-4.1,github-models:openai/gpt-4.1"
  ' _ "${probe_script}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "cloudflare-workers-ai:@cf/a cloudflare-workers-ai:@cf/c github-models:openai/gpt-4.1" ]
}

@test "emitted config carries model context7 and runbook instructions without cf block" {
  run bash -euo pipefail -c '
    source "$1"
    opencode_emit_config "opencode/big-pickle" "" "runbook.md" | jq -r "
      [.model,
       (.mcp.context7.url),
       (.instructions | join(\",\")),
       (has(\"provider\") | tostring)] | join(\"|\")
    "
  ' _ "${probe_script}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "opencode/big-pickle|https://mcp.context7.com/mcp|runbook.md|false" ]
}

@test "emitted config registers cf models on the built-in workers-ai provider" {
  run bash -euo pipefail -c '
    source "$1"
    opencode_emit_config "cloudflare-workers-ai/@cf/a" "cloudflare-workers-ai:@cf/a cloudflare-workers-ai:@cf/b" "runbook.md" | jq -r "
      [.model,
       (.provider[\"cloudflare-workers-ai\"].models | keys | sort | join(\",\"))] | join(\"|\")
    "
  ' _ "${probe_script}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "cloudflare-workers-ai/@cf/a|@cf/a,@cf/b" ]
}

@test "emitted config registers github-models provider block and model ids" {
  run bash -euo pipefail -c '
    source "$1"
    opencode_emit_config "github-models/openai/gpt-4.1" "github-models:openai/gpt-4.1" "runbook.md" | jq -r "
      [.model,
       .provider[\"github-models\"].npm,
       .provider[\"github-models\"].options.baseURL,
       .provider[\"github-models\"].options.apiKey,
       (.provider[\"github-models\"].models | keys | join(\",\"))] | join(\"|\")
    "
  ' _ "${probe_script}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "github-models/openai/gpt-4.1|@ai-sdk/openai-compatible|https://models.github.ai/inference|{env:GITHUB_TOKEN}|openai/gpt-4.1" ]
}

@test "emitted config omits github-models provider block when no gh model is selected" {
  run bash -euo pipefail -c '
    source "$1"
    opencode_emit_config "opencode/big-pickle" "cloudflare-workers-ai:@cf/a" "runbook.md" | jq -r "
      .provider | has(\"github-models\") | tostring
    "
  ' _ "${probe_script}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "false" ]
}

@test "provider env gate requires all plus-joined vars and any tilde alternative" {
  run env -u CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID=acct bash -euo pipefail -c '
    source "$1"
    opencode_probe_env_ok "CLOUDFLARE_ACCOUNT_ID+CLOUDFLARE_API_TOKEN"
  ' _ "${probe_script}"
  [ "${status}" -ne 0 ]

  run env CLOUDFLARE_ACCOUNT_ID=acct CLOUDFLARE_API_TOKEN=tok bash -euo pipefail -c '
    source "$1"
    opencode_probe_env_ok "CLOUDFLARE_ACCOUNT_ID+CLOUDFLARE_API_TOKEN"
  ' _ "${probe_script}"
  [ "${status}" -eq 0 ]

  run env -u GOOGLE_GENERATIVE_AI_API_KEY GEMINI_API_KEY=gem bash -euo pipefail -c '
    source "$1"
    opencode_probe_env_ok "GOOGLE_GENERATIVE_AI_API_KEY~GEMINI_API_KEY~GOOGLE_API_KEY" &&
      [ "$(opencode_probe_env_key "GOOGLE_GENERATIVE_AI_API_KEY~GEMINI_API_KEY~GOOGLE_API_KEY")" = "gem" ]
  ' _ "${probe_script}"
  [ "${status}" -eq 0 ]
}

@test "probe entry selects native provider models and skips missing credentials" {
  run env OPENROUTER_API_KEY=or-key bash -euo pipefail -c '
    source "$1"
    curl() { return 0; }
    opencode_probe_entry "openrouter:meta-llama/llama-3.3-70b-instruct:free"
  ' _ "${probe_script}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "openrouter/meta-llama/llama-3.3-70b-instruct:free" ]

  run env -u ANTHROPIC_API_KEY bash -euo pipefail -c '
    source "$1"
    opencode_probe_entry "anthropic:claude-sonnet-4-5" 2>/dev/null
  ' _ "${probe_script}"
  [ "${status}" -ne 0 ]
  [ -z "${output}" ]
}

@test "anthropic probe posts a messages request with the api key header" {
  run env ANTHROPIC_API_KEY=ak bash -euo pipefail -c '
    source "$1"
    curl() {
      for a in "$@"; do
        [[ "${a}" == "x-api-key: ak" ]] && found_key=1
        [[ "${a}" == *"api.anthropic.com/v1/messages"* ]] && found_url=1
        [[ "${a}" == *"claude-sonnet-4-5"* ]] && found_model=1
      done
      [[ "${found_key:-}" && "${found_url:-}" && "${found_model:-}" ]]
    }
    opencode_probe_entry "anthropic:claude-sonnet-4-5"
  ' _ "${probe_script}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "anthropic/claude-sonnet-4-5" ]
}

@test "emitted config merges over caller-provided OPENCODE_CONFIG_CONTENT" {
  run bash -euo pipefail -c '
    source "$1"
    OPENCODE_CONFIG_CONTENT="{\"custom\":{\"x\":1},\"instructions\":[\"caller.md\"]}" \
      opencode_emit_config "opencode/big-pickle" "" "runbook.md" | jq -r "
        [.custom.x, (.instructions | sort | join(\",\")), .model] | join(\"|\")
      "
  ' _ "${probe_script}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "1|caller.md,runbook.md|opencode/big-pickle" ]
}

@test "instructions prefer a repository runbook and fall back to the bundled absolute path" {
  touch "${fake_workspace}/.opencode/github-commands.md"
  run bash -euo pipefail -c '
    source "$1"
    opencode_probe_instructions "$2" "$3"
  ' _ "${probe_script}" "${fake_workspace}" "${fake_action}"
  [ "${status}" -eq 0 ]
  [ "${output}" = ".opencode/github-commands.md github-commands.md" ]

  rm "${fake_workspace}/.opencode/github-commands.md"
  run bash -euo pipefail -c '
    source "$1"
    opencode_probe_instructions "$2" "$3"
  ' _ "${probe_script}" "${fake_workspace}" "${fake_action}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "${fake_action}/.opencode/github-commands.md github-commands.md" ]

  run bash -euo pipefail -c '
    source "$1"
    opencode_probe_instructions "$2" "$3" false
  ' _ "${probe_script}" "${fake_workspace}" "${fake_action}"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]

  touch "${fake_workspace}/.opencode/github-commands.md"
  run bash -euo pipefail -c '
    source "$1"
    opencode_probe_instructions "$2" "$3" false
  ' _ "${probe_script}" "${fake_workspace}" "${fake_action}"
  [ "${status}" -eq 0 ]
  [ "${output}" = ".opencode/github-commands.md" ]
}

@test "explicit model skips probing and emits outputs and the config file" {
  github_output="${BATS_TEST_TMPDIR}/out"
  github_env="${BATS_TEST_TMPDIR}/env"
  fake_temp="${BATS_TEST_TMPDIR}/rt"
  mkdir -p "${fake_temp}"
  run env \
    MODEL="anthropic/claude-sonnet-4" \
    MODELS_REVIEW="cf:@cf/a" \
    MODELS_FIX="zen:b" \
    GITHUB_OUTPUT="${github_output}" \
    GITHUB_ENV="${github_env}" \
    RUNNER_TEMP="${fake_temp}" \
    ACTION_PATH="${fake_action}" \
    GITHUB_WORKSPACE="${fake_workspace}" \
    "${probe_script}"
  [ "${status}" -eq 0 ]
  grep -qx 'model=anthropic/claude-sonnet-4' "${github_output}"
  grep -qx 'OPENCODE_CONFIG_CONTENT<<EOF' "${github_env}"
  grep -qx "OPENCODE_PROBE_CONFIG_FILE=${fake_temp}/opencode-probe-config.json" "${github_env}"
  jq -e '.model == "anthropic/claude-sonnet-4"' "${fake_temp}/opencode-probe-config.json" > /dev/null
}

@test "explicit cloudflare model is registered on the workers-ai provider" {
  github_output="${BATS_TEST_TMPDIR}/out"
  github_env="${BATS_TEST_TMPDIR}/env"
  fake_temp="${BATS_TEST_TMPDIR}/rt"
  mkdir -p "${fake_temp}"
  run env \
    MODEL="cloudflare-workers-ai/@cf/custom" \
    MODELS_REVIEW="" \
    MODELS_FIX="" \
    GITHUB_OUTPUT="${github_output}" \
    GITHUB_ENV="${github_env}" \
    RUNNER_TEMP="${fake_temp}" \
    ACTION_PATH="${fake_action}" \
    GITHUB_WORKSPACE="${fake_workspace}" \
    "${probe_script}"
  [ "${status}" -eq 0 ]
  jq -e '.provider["cloudflare-workers-ai"].models["@cf/custom"]' \
    "${fake_temp}/opencode-probe-config.json" > /dev/null
}

@test "explicit model without provider prefix is rejected" {
  run env \
    MODEL="just-a-model" \
    GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/out" \
    GITHUB_ENV="${BATS_TEST_TMPDIR}/env" \
    RUNNER_TEMP="${BATS_TEST_TMPDIR}" \
    ACTION_PATH="${fake_action}" \
    "${probe_script}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"provider/model"* ]]
}
