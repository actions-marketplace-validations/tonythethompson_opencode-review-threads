#!/usr/bin/env bash
# Select the model for this run and emit the inline OpenCode configuration.
# Functions are sourceable for tests.
#
# When MODEL is set it is used verbatim (provider/model) and no endpoint is
# probed. Otherwise the comma-separated chain for the run kind is walked and
# the first reachable entry wins:
#   cf:<model>          probe the Cloudflare Workers AI OpenAI-compatible
#                       endpoint; selected as cloudflare-workers-ai/<model>
#   zen:<model>         probe the opencode.ai Zen gateway; selected as
#                       opencode/<model>
#   <provider>/<model>  selected without probing; the caller is responsible for
#                       the provider credentials in env
#
# Env in:  MODEL (optional), PROMPT, MENTIONS, GITHUB_EVENT_PATH,
#          GITHUB_EVENT_NAME, MODELS_REVIEW, MODELS_FIX, OPENCODE_API_KEY,
#          CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_API_TOKEN, ACTION_PATH,
#          GITHUB_WORKSPACE, RUNNER_TEMP, OPENCODE_CONFIG_CONTENT (optional
#          caller-provided base config that the emitted config is merged over)
# Out:     $GITHUB_OUTPUT  -> model
#          $GITHUB_ENV     -> OPENCODE_CONFIG_CONTENT, OPENCODE_PROBE_CONFIG_FILE
#
# The emitted config is also written to a file so review-only mode can re-import
# this action-generated (trusted) config after caller-supplied overrides are
# unset; see run-opencode.sh.

# A run counts as a review when the event is a pull_request trigger (the
# review workflow), when the effective prompt is the bundled /review-pr
# command, or when it is a `/oc review`-style request (the mention is already
# stripped by opencode_effective_prompt).
opencode_probe_is_review() {
  local effective_prompt="${1:-}" event_name="${2:-}"
  [[ "${event_name}" == "pull_request" ]] && return 0
  [[ "${effective_prompt}" =~ ^/review-pr([[:space:]]|$) ]] && return 0
  [[ "${effective_prompt}" =~ ^review([[:space:]]|$) ]] && return 0
  return 1
}

opencode_probe_zen() {
  local model="${1}"
  curl -sf --max-time 15 -X POST "https://opencode.ai/zen/v1/chat/completions" \
    -H "Authorization: Bearer ${OPENCODE_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":1}" \
    > /dev/null 2>&1
}

opencode_probe_cf() {
  local model="${1}"
  curl -sf --max-time 20 -X POST \
    "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/ai/v1/chat/completions" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":1}" \
    > /dev/null 2>&1
}

# Space-separated list of Cloudflare Workers AI model ids appearing in the
# given comma-separated chains (cf: entries only, deduplicated).
opencode_probe_cf_models() {
  local chains="${1}" entry model out=""
  local -a entries
  IFS=',' read -r -a entries <<< "${chains}"
  for entry in "${entries[@]}"; do
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [[ "${entry}" == cf:* ]] || continue
    model="${entry#cf:}"
    case " ${out} " in
      *" ${model} "*) ;;
      *) out+="${out:+ }${model}" ;;
    esac
  done
  printf '%s' "${out}"
}

# Instruction entries for the emitted config. A repository that ships its own
# .opencode/github-commands.md wins; otherwise the bundled runbook is referenced
# by absolute path so nothing is written into the workspace (an injected file
# could otherwise end up committed by the agent). "github-commands.md" is
# always included alongside the bundled runbook: in review-only mode relative
# instructions resolve under the installed global config dir, where the bundled
# runbook is placed. With use-bundled-toolkit disabled, only a repository's own
# runbook is referenced.
opencode_probe_instructions() {
  local workspace="${1:-}" action_path="${2:-}" bundled_toolkit="${3:-true}"
  if [[ -n "${workspace}" && -f "${workspace}/.opencode/github-commands.md" ]]; then
    printf '.opencode/github-commands.md'
    [[ "${bundled_toolkit}" == "true" ]] && printf ' github-commands.md'
    printf '\n'
  elif [[ "${bundled_toolkit}" == "true" ]]; then
    printf '%s/.opencode/github-commands.md github-commands.md\n' "${action_path}"
  else
    printf '\n'
  fi
}

# Emit the inline config shared by every selection: context7 MCP, the GitHub
# command runbook instructions, and the cloudflare-workers-ai model registry
# when cf_models is non-empty. Caller-provided OPENCODE_CONFIG_CONTENT is used
# as a merge base when present.
opencode_emit_config() {
  local model="${1}" cf_models="${2:-}" instructions="${3}"
  local base="${OPENCODE_CONFIG_CONTENT:-"{}"}"
  jq -n \
    --arg model "${model}" \
    --arg cf "${cf_models}" \
    --arg instructions "${instructions}" \
    --argjson base "${base}" '
    ($instructions | split(" ") | map(select(length > 0))) as $instr
    | ($cf | split(" ") | map(select(length > 0))
      | map({key: ., value: {name: .}}) | from_entries) as $cf_models
    | ({
        "mcp": {
          "context7": {
            "type": "remote",
            "url": "https://mcp.context7.com/mcp",
            "oauth": false,
            "headers": { "CONTEXT7_API_KEY": "{env:CONTEXT7_API_KEY}" },
            "enabled": true
          }
        },
        "model": $model
      }
      | if ($cf_models | length) > 0 then
          .provider = { "cloudflare-workers-ai": { "models": $cf_models } }
        else . end) as $emitted
    | ($base * $emitted)
    | .instructions = ((($base.instructions // []) + $instr) | unique)
    | . + { "$schema": "https://opencode.ai/config.json" }'
}

_opencode_probe_choose() {
  local model="${1}" cf_models="${2:-}" instructions config_json probe_file
  instructions="$(opencode_probe_instructions \
    "${GITHUB_WORKSPACE:-}" "${ACTION_PATH:-}" "${USE_BUNDLED_TOOLKIT:-true}")"
  config_json="$(opencode_emit_config "${model}" "${cf_models}" "${instructions}")" || {
    echo "::error::Failed to render OpenCode config for model '${model}'."
    exit 1
  }
  probe_file="${RUNNER_TEMP:-$(mktemp -d)}/opencode-probe-config.json"
  printf '%s\n' "${config_json}" > "${probe_file}"
  {
    printf 'model=%s\n' "${model}"
  } >> "${GITHUB_OUTPUT}"
  {
    printf 'OPENCODE_CONFIG_CONTENT<<EOF\n'
    printf '%s\n' "${config_json}"
    printf 'EOF\n'
    printf 'OPENCODE_PROBE_CONFIG_FILE=%s\n' "${probe_file}"
  } >> "${GITHUB_ENV}"
  echo "::notice::Selected model ${model}"
  exit 0
}

_opencode_probe_main() {
  local script_dir chain_kind chain entries entry model cf_models
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # shellcheck source=scripts/opencode-action-lib.sh
  source "${script_dir}/opencode-action-lib.sh"

  cf_models="$(opencode_probe_cf_models "${MODELS_REVIEW:-},${MODELS_FIX:-}")"

  if [[ -n "${MODEL:-}" ]]; then
    if [[ "${MODEL}" != */* ]]; then
      echo "::error::Invalid model '${MODEL}'. Model must be in the format 'provider/model'."
      exit 1
    fi
    # Register an explicit cloudflare-workers-ai model id on the built-in
    # provider even when it is not part of a probe chain.
    if [[ "${MODEL}" == cloudflare-workers-ai/* ]]; then
      model="${MODEL#cloudflare-workers-ai/}"
      case " ${cf_models} " in
        *" ${model} "*) ;;
        *) cf_models+="${cf_models:+ }${model}" ;;
      esac
    fi
    echo "::notice::Using explicit model ${MODEL} (probing skipped)"
    _opencode_probe_choose "${MODEL}" "${cf_models}"
  fi

  opencode_effective_prompt "${PROMPT:-}" "${MENTIONS:-}" "${GITHUB_EVENT_PATH:-}"
  if opencode_probe_is_review "${OPENCODE_EFFECTIVE_PROMPT:-}" "${GITHUB_EVENT_NAME:-}"; then
    chain_kind="review"
    chain="${MODELS_REVIEW:?MODELS_REVIEW is required}"
  else
    chain_kind="fix"
    chain="${MODELS_FIX:?MODELS_FIX is required}"
  fi
  echo "::notice::Probing ${chain_kind} chain: ${chain}"

  IFS=',' read -r -a entries <<< "${chain}"
  for entry in "${entries[@]}"; do
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [[ -n "${entry}" ]] || continue
    case "${entry}" in
      cf:*)
        model="${entry#cf:}"
        if [[ -z "${CLOUDFLARE_API_TOKEN:-}" || -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]]; then
          echo "::warning::Skipping ${entry} - CLOUDFLARE_ACCOUNT_ID/CLOUDFLARE_API_TOKEN not set"
          continue
        fi
        if opencode_probe_cf "${model}"; then
          _opencode_probe_choose "cloudflare-workers-ai/${model}" "${cf_models}"
        fi
        echo "::warning::${entry} unavailable - trying next"
        ;;
      zen:*)
        model="${entry#zen:}"
        if [[ -z "${OPENCODE_API_KEY:-}" ]]; then
          echo "::warning::Skipping ${entry} - OPENCODE_API_KEY not set"
          continue
        fi
        if opencode_probe_zen "${model}"; then
          _opencode_probe_choose "opencode/${model}" "${cf_models}"
        fi
        echo "::warning::${entry} unavailable - trying next"
        ;;
      *)
        echo "::notice::${entry} is selected without probing"
        _opencode_probe_choose "${entry}" "${cf_models}"
        ;;
    esac
  done

  echo "::error::No model in the ${chain_kind} chain was reachable. Set the 'model' input to select one explicitly."
  exit 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  _opencode_probe_main
fi
