#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  shim_src="${repo_root}/scripts/gh-app-token-shim.sh"
  fake_bin="${BATS_TEST_TMPDIR}/bin"
  shim_dir="${BATS_TEST_TMPDIR}/shim"
  fake_action="${BATS_TEST_TMPDIR}/action"
  fake_home="${BATS_TEST_TMPDIR}/home"
  fake_tmp="${BATS_TEST_TMPDIR}/tmp"
  mkdir -p "${fake_bin}" "${shim_dir}" "${fake_action}/.opencode/scripts" "${fake_home}" "${fake_tmp}"

  cat > "${fake_bin}/gh" <<'EOF'
#!/usr/bin/env bash
printf 'GH_TOKEN=%s GITHUB_TOKEN=%s args=%s\n' "${GH_TOKEN:-none}" "${GITHUB_TOKEN:-none}" "$*"
EOF
  chmod +x "${fake_bin}/gh"

  sed "s|__REAL_GH__|${fake_bin}/gh|g" "${shim_src}" > "${shim_dir}/gh"
  chmod +x "${shim_dir}/gh"

  export TMPDIR="${fake_tmp}"
  export HOME="${fake_home}"
  export GITHUB_RUN_ID="test-run-1"
  export ACTION_PATH="${fake_action}"
}

@test "shim passes ambient token through when nothing is resolvable" {
  run env GH_TOKEN=workflowtoken "${shim_dir}/gh" api repos/x/y
  [ "${status}" -eq 0 ]
  [ "${output}" = "GH_TOKEN=workflowtoken GITHUB_TOKEN=none args=api repos/x/y" ]
}

@test "shim passes through under use-github-token: true even with a cached app token" {
  printf 'apptok123\n' > "${TMPDIR}/opencode-app-token.${GITHUB_RUN_ID}"
  run env USE_GITHUB_TOKEN=true GH_TOKEN=workflowtoken "${shim_dir}/gh" api repos/x/y
  [ "${status}" -eq 0 ]
  [ "${output}" = "GH_TOKEN=workflowtoken GITHUB_TOKEN=none args=api repos/x/y" ]
}

@test "shim exports cached app token over the ambient token" {
  printf 'apptok123\n' > "${TMPDIR}/opencode-app-token.${GITHUB_RUN_ID}"
  run env GH_TOKEN=workflowtoken "${shim_dir}/gh" api repos/x/y
  [ "${status}" -eq 0 ]
  [ "${output}" = "GH_TOKEN=apptok123 GITHUB_TOKEN=apptok123 args=api repos/x/y" ]
}

@test "shim resolves, verifies, caches, and exports an app token candidate" {
  cat > "${fake_action}/.opencode/scripts/resolve-app-token.sh" <<'EOF'
opencode_resolve_app_token_candidates() { printf 'candidate-tok\n'; }
opencode_verify_app_token_identity() { [ "$3" = "candidate-tok" ]; }
EOF
  printf '{"pull_request":{"number":7}}' > "${BATS_TEST_TMPDIR}/event.json"
  run env GH_TOKEN=workflowtoken GITHUB_REPOSITORY=owner/repo \
    GITHUB_EVENT_PATH="${BATS_TEST_TMPDIR}/event.json" "${shim_dir}/gh" api repos/x/y
  [ "${status}" -eq 0 ]
  [ "${output}" = "GH_TOKEN=candidate-tok GITHUB_TOKEN=candidate-tok args=api repos/x/y" ]
  [ -f "${TMPDIR}/opencode-app-token.${GITHUB_RUN_ID}" ]
  [ "$(cat "${TMPDIR}/opencode-app-token.${GITHUB_RUN_ID}")" = "candidate-tok" ]
}

@test "shim does not export an unverified candidate" {
  cat > "${fake_action}/.opencode/scripts/resolve-app-token.sh" <<'EOF'
opencode_resolve_app_token_candidates() { printf 'wrong-tok\n'; }
opencode_verify_app_token_identity() { return 1; }
EOF
  printf '{"pull_request":{"number":7}}' > "${BATS_TEST_TMPDIR}/event.json"
  run env GH_TOKEN=workflowtoken GITHUB_REPOSITORY=owner/repo \
    GITHUB_EVENT_PATH="${BATS_TEST_TMPDIR}/event.json" "${shim_dir}/gh" api repos/x/y
  [ "${status}" -eq 0 ]
  [ "${output}" = "GH_TOKEN=workflowtoken GITHUB_TOKEN=none args=api repos/x/y" ]
  [ ! -f "${TMPDIR}/opencode-app-token.${GITHUB_RUN_ID}" ]
}

@test "shim short-circuits to real gh while resolving (no recursion)" {
  cat > "${fake_action}/.opencode/scripts/resolve-app-token.sh" <<'EOF'
opencode_resolve_app_token_candidates() { printf 'candidate-tok\n'; }
opencode_verify_app_token_identity() { gh api --version >/dev/null 2>&1; }
EOF
  printf '{"pull_request":{"number":7}}' > "${BATS_TEST_TMPDIR}/event.json"
  run env GH_TOKEN=workflowtoken GITHUB_REPOSITORY=owner/repo \
    GITHUB_EVENT_PATH="${BATS_TEST_TMPDIR}/event.json" PATH="${shim_dir}:${PATH}" \
    "${shim_dir}/gh" api repos/x/y
  [ "${status}" -eq 0 ]
  [[ "${output}" == GH_TOKEN=* ]]
}
