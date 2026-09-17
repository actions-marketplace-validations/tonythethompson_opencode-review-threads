#!/usr/bin/env bash
# Run scripts/run-opencode.sh under a shared wall-clock deadline, with one
# retry. Between attempts the script first tries to salvage agent commits the
# CLI made locally before a rejected push (remote advanced mid-run), then
# resyncs the checkout's branch to the remote so a re-run pushes fast-forward.
#
# Env in: TIMEOUT_MINUTES  total agent budget in minutes, shared by both attempts
#         JOB_STARTED_AT   epoch the job started (defaults to this script's start)
#         GH_TOKEN         token used for salvage push auth (optional; without it
#                          salvage relies on credentials already in git config)
#         plus everything scripts/run-opencode.sh consumes (MODEL, PROMPT, ...)

opencode_retry_salvage() {
  local branch="${1}"
  local ahead
  [[ -n "${branch}" && "${branch}" != "HEAD" ]] || return 1

  echo "==> salvaging agent commits onto updated remote (branch: ${branch})"
  # actions/checkout is typically run with persist-credentials: false, so give
  # git a token explicitly before fetching or pushing.
  if [[ -n "${GH_TOKEN:-}" ]]; then
    git config --local http.https://github.com/.extraheader \
      "AUTHORIZATION: basic $(printf 'x-access-token:%s' "${GH_TOKEN}" | base64 -w 0)" 2> /dev/null || true
  fi
  git fetch --prune origin 2> /dev/null || true
  git rev-parse --verify "origin/${branch}" > /dev/null 2>&1 || return 1
  ahead="$(git rev-list --count "origin/${branch}"..HEAD 2> /dev/null || echo 0)"
  if ((ahead == 0)); then
    echo "::notice::no local-only commits; failure was not a rejected push"
    return 1
  fi
  if git rebase "origin/${branch}"; then
    if git push 2> /dev/null; then
      echo "::notice::salvaged agent work: rebased onto origin/${branch} and pushed"
      return 0
    fi
    echo "::warning::salvage push failed; falling back to synced re-run"
  fi
  git rebase --abort 2> /dev/null || true
  return 1
}

opencode_retry_resync() {
  local branch="${1}"
  [[ -n "${branch}" && "${branch}" != "HEAD" ]] || return 0

  echo "==> syncing branch to remote and retrying once"
  git fetch --prune origin 2> /dev/null || true
  if git rev-parse --verify "origin/${branch}" > /dev/null 2>&1; then
    git checkout -B "${branch}" "origin/${branch}" > /dev/null 2>&1 || true
    git reset --hard "origin/${branch}" > /dev/null 2>&1 || true
  fi
}

_opencode_retry_main() {
  local script_dir deadline branch status
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # Absolute deadline for agent work; both attempts share it so a retry can
  # never overrun the job. run-opencode.sh reads OPENCODE_DEADLINE_EPOCH and
  # translates it into `timeout --signal=TERM --kill-after=60 <budget>`.
  deadline=$((${JOB_STARTED_AT:-$(date +%s)} + ${TIMEOUT_MINUTES:?TIMEOUT_MINUTES is required} * 60))
  export OPENCODE_DEADLINE_EPOCH="${deadline}"

  if (($(date +%s) >= deadline)); then
    echo "::error::No time budget remains for opencode (deadline already passed)."
    return 124
  fi

  status=0
  "${script_dir}/run-opencode.sh" || status=$?
  if ((status == 0)); then
    echo "::notice::opencode github run succeeded (attempt 1)"
    return 0
  fi
  echo "::warning::opencode github run failed on attempt 1 (exit ${status})"

  branch="$(git rev-parse --abbrev-ref HEAD 2> /dev/null || echo '')"
  if opencode_retry_salvage "${branch}"; then
    return 0
  fi
  opencode_retry_resync "${branch}"

  if (($(date +%s) >= deadline)); then
    echo "::error::No time budget remains for a retry (deadline already passed)."
    return 124
  fi

  status=0
  "${script_dir}/run-opencode.sh" || status=$?
  if ((status == 0)); then
    echo "::notice::opencode github run succeeded on retry"
    return 0
  fi
  echo "::error::opencode github run failed on both attempts"
  return "${status}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  _opencode_retry_main
fi
