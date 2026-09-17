#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  install_script="${repo_root}/scripts/install-opencode.sh"
  fake_bin="${BATS_TEST_TMPDIR}/bin"
  fake_home="${BATS_TEST_TMPDIR}/home"
  mkdir -p "${fake_bin}" "${fake_home}"
}

_fake_curl_release() {
  # $1: directory to receive the stub; $2: asset name; $3: digest
  # The stub answers the release-metadata call with canned JSON and the
  # download call with a real archive containing a fake opencode binary.
  local stub_dir="${1}" asset="${2}" digest="${3}"
  local payload="${BATS_TEST_TMPDIR}/payload-${asset}"
  mkdir -p "${BATS_TEST_TMPDIR}/payload-src"
  printf '#!/bin/sh\necho fake\n' > "${BATS_TEST_TMPDIR}/payload-src/opencode"
  case "${asset}" in
    *.tar.gz)
      tar -czf "${payload}" -C "${BATS_TEST_TMPDIR}/payload-src" opencode
      ;;
    *.zip)
      (cd "${BATS_TEST_TMPDIR}/payload-src" && zip -q "${payload}" opencode)
      ;;
  esac
  cat > "${stub_dir}/curl" << EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\${arg}" in
    *api.github.com*)
      printf '%s' '{"assets":[{"name":"${asset}","browser_download_url":"https://example.test/${asset}","digest":"sha256:${digest}"}]}'
      exit 0
      ;;
    https://example.test/*)
      cat "${payload}"
      exit 0
      ;;
  esac
done
exit 0
EOF
  chmod +x "${stub_dir}/curl"
}

@test "asset and binary names cover the supported runner matrix" {
  run bash -euo pipefail -c '
    source "$1"
    opencode_install_asset_name Linux X64
  ' _ "${install_script}"
  [ "${output}" = "opencode-linux-x64.tar.gz" ]
  run bash -euo pipefail -c '
    source "$1"
    opencode_install_asset_name macOS ARM64
  ' _ "${install_script}"
  [ "${output}" = "opencode-darwin-arm64.zip" ]
  run bash -euo pipefail -c '
    source "$1"
    opencode_install_asset_name Windows X64
  ' _ "${install_script}"
  [ "${output}" = "opencode-windows-x64.zip" ]
  run bash -euo pipefail -c '
    source "$1"
    opencode_install_binary_name Windows
  ' _ "${install_script}"
  [ "${output}" = "opencode.exe" ]
  run bash -euo pipefail -c '
    source "$1"
    opencode_install_asset_name FreeBSD X64
  ' _ "${install_script}"
  [ "${status}" -ne 0 ]
}

@test "install verifies the sha256 digest and extracts the binary" {
  if ! command -v sha256sum > /dev/null 2>&1; then
    skip "sha256sum is not available"
  fi
  payload="${BATS_TEST_TMPDIR}/opencode-linux-x64.tar.gz"
  mkdir -p "${BATS_TEST_TMPDIR}/src"
  printf '#!/bin/sh\necho fake\n' > "${BATS_TEST_TMPDIR}/src/opencode"
  tar -czf "${payload}" -C "${BATS_TEST_TMPDIR}/src" opencode
  digest="$(sha256sum "${payload}" | awk '{print $1}')"

  cat > "${fake_bin}/curl" << EOF
#!/usr/bin/env bash
next_is_out=""
for arg in "\$@"; do
  if [[ "\${next_is_out}" == "true" ]]; then
    cat "${payload}" > "\${arg}"
    exit 0
  fi
  [[ "\${arg}" == "-o" ]] && next_is_out="true"
  case "\${arg}" in
    *api.github.com*)
      printf '%s' '{"assets":[{"name":"opencode-linux-x64.tar.gz","browser_download_url":"https://example.test/a","digest":"sha256:${digest}"}]}'
      ;;
  esac
done
exit 0
EOF
  chmod +x "${fake_bin}/curl"

  run env \
    PATH="${fake_bin}:${PATH}" \
    HOME="${fake_home}" \
    OPENCODE_VERSION="9.9.9" \
    RUNNER_OS="Linux" \
    RUNNER_ARCH="X64" \
    "${install_script}"
  [ "${status}" -eq 0 ]
  [ -x "${fake_home}/.opencode/bin/opencode" ]
  [[ "${output}" == *"sha256 verified"* ]]
}

@test "install fails when the release asset has no digest" {
  cat > "${fake_bin}/curl" << 'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  case "${arg}" in
    *api.github.com*)
      printf '%s' '{"assets":[{"name":"opencode-linux-x64.tar.gz","browser_download_url":"https://example.test/a"}]}'
      ;;
  esac
done
exit 0
EOF
  chmod +x "${fake_bin}/curl"

  run env \
    PATH="${fake_bin}:${PATH}" \
    HOME="${fake_home}" \
    OPENCODE_VERSION="9.9.9" \
    RUNNER_OS="Linux" \
    RUNNER_ARCH="X64" \
    "${install_script}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Failed to resolve release asset"* ]]
}
