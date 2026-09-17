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

@test "cf model collection deduplicates cf: entries across both chains" {
  run bash -euo pipefail -c '
    source "$1"
    opencode_probe_cf_models "cf:@cf/a,zen:b, cf:@cf/c ,other/x,cf:@cf/a"
  ' _ "${probe_script}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "@cf/a @cf/c" ]
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
    opencode_emit_config "cloudflare-workers-ai/@cf/a" "@cf/a @cf/b" "runbook.md" | jq -r "
      [.model,
       (.provider[\"cloudflare-workers-ai\"].models | keys | sort | join(\",\"))] | join(\"|\")
    "
  ' _ "${probe_script}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "cloudflare-workers-ai/@cf/a|@cf/a,@cf/b" ]
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
