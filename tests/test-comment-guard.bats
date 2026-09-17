#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  guard_script="${repo_root}/scripts/comment-guard.sh"
  fake_bin="${BATS_TEST_TMPDIR}/bin"
  fake_temp="${BATS_TEST_TMPDIR}/rt"
  mkdir -p "${fake_bin}" "${fake_temp}"
  export RUNNER_TEMP="${fake_temp}"
  export REPOSITORY="owner/repo"
  export PR_NUM="7"

  # gh stub: serves canned comment lists from $FAKE_ISSUE_COMMENTS and
  # $FAKE_PULL_COMMENTS (JSON array files the test mutates between calls).
  cat > "${fake_bin}/gh" << 'EOF'
#!/usr/bin/env bash
url="" jq_expr="" slurp="" prev=""
for arg in "$@"; do
  if [[ "${prev}" == "--jq" ]]; then jq_expr="${arg}"; fi
  case "${arg}" in
    repos/*) url="${arg}" ;;
    --slurp) slurp="true" ;;
  esac
  prev="${arg}"
done
case "${url}" in
  */issues/*) file="${FAKE_ISSUE_COMMENTS:?}" ;;
  */pulls/*) file="${FAKE_PULL_COMMENTS:?}" ;;
  *) exit 1 ;;
esac
if [[ -n "${slurp}" ]]; then
  printf '[%s]' "$(cat "${file}")"
elif [[ -n "${jq_expr}" ]]; then
  jq -r "${jq_expr}" "${file}"
fi
EOF
  chmod +x "${fake_bin}/gh"
  export PATH="${fake_bin}:${PATH}"

  issue_file="${BATS_TEST_TMPDIR}/issue.json"
  pull_file="${BATS_TEST_TMPDIR}/pull.json"
  printf '[{"id":11,"body":"old"}]\n' > "${issue_file}"
  printf '[{"id":22,"body":"older"}]\n' > "${pull_file}"
  export FAKE_ISSUE_COMMENTS="${issue_file}"
  export FAKE_PULL_COMMENTS="${pull_file}"
}

@test "snapshot records sorted issue and review comment ids" {
  run "${guard_script}" snapshot
  [ "${status}" -eq 0 ]
  run cat "${RUNNER_TEMP}/opencode-comments-before"
  [ "${output}" = $'11\n22' ]
}

@test "verify passes when no new comments were posted" {
  "${guard_script}" snapshot
  run "${guard_script}" verify
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"No new comments"* ]]
}

@test "verify passes clean new comments" {
  "${guard_script}" snapshot
  printf '[{"id":11,"body":"old"},{"id":33,"body":"looks good to me"}]\n' > "${FAKE_ISSUE_COMMENTS}"
  run "${guard_script}" verify
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"No leaked path tokens"* ]]
}

@test "verify fails when a new comment leaks an @path token" {
  "${guard_script}" snapshot
  printf '[{"id":11,"body":"old"},{"id":33,"body":"see @/tmp/opencode/finding.md"}]\n' > "${FAKE_ISSUE_COMMENTS}"
  run "${guard_script}" verify
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"leaked path token"* ]]
}

@test "verify fails when a new review comment leaks a /tmp/ path" {
  "${guard_script}" snapshot
  printf '[{"id":22,"body":"older"},{"id":44,"body":"content lives in /tmp/opencode/x.md"}]\n' > "${FAKE_PULL_COMMENTS}"
  run "${guard_script}" verify
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"leaked path token"* ]]
}

@test "verify warns and passes without a prior snapshot" {
  run "${guard_script}" verify
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"snapshot is unavailable"* ]]
}

@test "verify is a no-op without a PR number" {
  unset PR_NUM
  run "${guard_script}" verify
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "unknown subcommand fails" {
  run "${guard_script}" frobnicate
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Unknown comment-guard command"* ]]
}
