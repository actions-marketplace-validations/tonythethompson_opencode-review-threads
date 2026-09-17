#!/usr/bin/env bash
# Detection net for the leaked-`@path` failure mode. `opencode github run`
# posts the agent's reply text verbatim, so if a reply references a temp file
# (e.g. "@/tmp/opencode/summary.md") that token leaks into a public comment.
#
# Subcommands:
#   snapshot  record the current issue+review comment ids for the PR
#   verify    diff the snapshot against current comments and fail if any new
#             comment body contains a `@/` or `/tmp/` path token
#
# Env in: GH_TOKEN, REPOSITORY (owner/name), PR_NUM, RUNNER_TEMP (optional)

_opencode_guard_state_dir() {
  printf '%s' "${RUNNER_TEMP:-$(mktemp -d)}"
}

opencode_comment_snapshot() {
  local before
  before="$(_opencode_guard_state_dir)/opencode-comments-before"
  : > "${before}"
  if [[ -n "${PR_NUM:-}" ]]; then
    gh api "repos/${REPOSITORY}/issues/${PR_NUM}/comments" --paginate --jq '.[].id' >> "${before}"
    gh api "repos/${REPOSITORY}/pulls/${PR_NUM}/comments" --paginate --jq '.[].id' >> "${before}"
    sort -n -o "${before}" "${before}"
  fi
}

opencode_comment_verify() {
  local state_dir before after new_ids issue_json review_json new_ids_json leaked
  state_dir="$(_opencode_guard_state_dir)"
  before="${state_dir}/opencode-comments-before"
  after="${state_dir}/opencode-comments-after"
  new_ids="${state_dir}/opencode-comments-new"
  issue_json="${state_dir}/opencode-issue-comments.json"
  review_json="${state_dir}/opencode-review-comments.json"

  [[ -n "${PR_NUM:-}" ]] || return 0
  : > "${after}"
  if [[ ! -f "${before}" ]]; then
    echo "::warning::Comment snapshot is unavailable; no agent invocation was verified."
    return 0
  fi

  gh api "repos/${REPOSITORY}/issues/${PR_NUM}/comments" --paginate --jq '.[].id' >> "${after}"
  gh api "repos/${REPOSITORY}/pulls/${PR_NUM}/comments" --paginate --jq '.[].id' >> "${after}"
  sort -n -o "${after}" "${after}"
  comm -13 "${before}" "${after}" > "${new_ids}"
  if [[ ! -s "${new_ids}" ]]; then
    echo "::notice::No new comments were posted by this invocation."
    return 0
  fi

  gh api "repos/${REPOSITORY}/issues/${PR_NUM}/comments" --paginate --slurp | jq 'add' > "${issue_json}"
  gh api "repos/${REPOSITORY}/pulls/${PR_NUM}/comments" --paginate --slurp | jq 'add' > "${review_json}"
  new_ids_json="$(jq -Rsc '[split("\n")[] | select(length > 0) | tonumber]' "${new_ids}")"
  leaked="$({
    jq -r --argjson ids "${new_ids_json}" \
      '.[] | select(.id as $id | ($ids | index($id)) != null) | .body' "${issue_json}"
    jq -r --argjson ids "${new_ids_json}" \
      '.[] | select(.id as $id | ($ids | index($id)) != null) | .body' "${review_json}"
  } | grep -E '@/|/tmp/' || true)"
  if [[ -n "${leaked}" ]]; then
    echo "::error::A comment posted by this run contains a leaked path token instead of content:"
    echo "${leaked}"
    echo "The temp file no longer exists on this runner, so the intended content cannot"
    echo "be recovered. Re-run the command and inline the content rather than a @/tmp/... path."
    return 1
  fi
  echo "::notice::No leaked path tokens in comments posted by this run."
}

_opencode_guard_main() {
  local command="${1:?usage: comment-guard.sh snapshot|verify}"
  case "${command}" in
    snapshot) opencode_comment_snapshot ;;
    verify) opencode_comment_verify ;;
    *)
      echo "::error::Unknown comment-guard command '${command}'." >&2
      return 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  _opencode_guard_main "$@"
fi
