#!/usr/bin/env bash
# gh shim for the OpenCode agent session.
#
# `opencode github run` performs the OIDC exchange internally and persists
# the OpenCode App installation token in git credential config. The gh CLI
# never reads git config, so improvised `gh api` calls by the agent (i.e.
# anything outside the guarded submit scripts) would author GitHub writes as
# github-actions[bot] via the ambient workflow token. This shim re-exports a
# verified App token for every gh invocation so authorship stays
# opencode-agent[bot] regardless of which path the agent takes.
#
# Installed at run time into a private PATH-prepended directory by
# run-opencode.sh; __REAL_GH__ is substituted with the resolved gh binary.
#
# Pass-through (no rewriting) when:
#   - use-github-token: true (explicit caller opt-in)
#   - no verified App token is resolvable yet (e.g. before the exchange)
#   - the bundled token resolver library is unavailable
set -u

REAL_GH="__REAL_GH__"

if [[ "${USE_GITHUB_TOKEN:-false}" == "true" || -n "${OC_GH_SHIM_RESOLVING:-}" ]]; then
  exec "${REAL_GH}" "$@"
fi

cache="${TMPDIR:-/tmp}/opencode-app-token.${GITHUB_RUN_ID:-session}"
token=""
if [[ -f "${cache}" ]]; then
  token="$(head -n 1 "${cache}" 2>/dev/null || true)"
fi

if [[ -z "${token}" ]]; then
  lib="${ACTION_PATH:-}/.opencode/scripts/resolve-app-token.sh"
  [[ -f "${lib}" ]] || lib="${HOME}/.config/opencode/scripts/resolve-app-token.sh"
  if [[ -f "${lib}" ]]; then
    # shellcheck source=.opencode/scripts/resolve-app-token.sh
    source "${lib}"
    repo="${GITHUB_REPOSITORY:-}"
    pr_num=""
    if [[ -n "${GITHUB_EVENT_PATH:-}" && -f "${GITHUB_EVENT_PATH}" ]]; then
      pr_num="$(jq -r '.pull_request.number // .issue.number // .number // empty' \
        "${GITHUB_EVENT_PATH}" 2>/dev/null || true)"
    fi
    if [[ -n "${repo}" && -n "${pr_num}" ]]; then
      export OC_GH_SHIM_RESOLVING=1
      candidate=""
      while IFS= read -r candidate; do
        [[ -n "${candidate}" ]] || continue
        if opencode_verify_app_token_identity "${repo}" "${pr_num}" "${candidate}"; then
          token="${candidate}"
          umask 077
          printf '%s\n' "${token}" >"${cache}"
          break
        fi
      done < <(opencode_resolve_app_token_candidates)
      unset OC_GH_SHIM_RESOLVING
    fi
  fi
fi

if [[ -n "${token}" ]]; then
  export GH_TOKEN="${token}"
  export GITHUB_TOKEN="${token}"
fi

exec "${REAL_GH}" "$@"
