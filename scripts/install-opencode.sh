#!/usr/bin/env bash
# Download the OpenCode release asset for this runner, verify its sha256
# against the digest published on the GitHub release, and install the binary
# into ~/.opencode/bin. Functions are sourceable for tests.
#
# Env in: OPENCODE_VERSION  release version without the leading "v"
#         RUNNER_OS         Linux | macOS | Windows
#         RUNNER_ARCH       X64 | ARM64
#         GITHUB_TOKEN      optional, avoids unauthenticated API rate limits

opencode_install_asset_name() {
  local runner_os="${1}" runner_arch="${2}"
  local os_part arch_part
  case "${runner_os}" in
    Linux) os_part="linux" ;;
    macOS) os_part="darwin" ;;
    Windows) os_part="windows" ;;
    *)
      echo "::error::Unsupported runner OS '${runner_os}'." >&2
      return 1
      ;;
  esac
  case "${runner_arch}" in
    X64) arch_part="x64" ;;
    ARM64) arch_part="arm64" ;;
    *)
      echo "::error::Unsupported runner architecture '${runner_arch}'." >&2
      return 1
      ;;
  esac
  if [[ "${os_part}" == "linux" ]]; then
    printf 'opencode-%s-%s.tar.gz' "${os_part}" "${arch_part}"
  else
    printf 'opencode-%s-%s.zip' "${os_part}" "${arch_part}"
  fi
}

opencode_install_binary_name() {
  if [[ "${1}" == "Windows" ]]; then
    printf 'opencode.exe'
  else
    printf 'opencode'
  fi
}

opencode_install() {
  local version="${1}" runner_os="${2}" runner_arch="${3}"
  local asset binary release url digest archive bin_dir
  local -a auth_header=()

  asset="$(opencode_install_asset_name "${runner_os}" "${runner_arch}")" || return 1
  binary="$(opencode_install_binary_name "${runner_os}")"

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    auth_header=(-H "Authorization: token ${GITHUB_TOKEN}")
  fi
  release="$(curl -fsSL "${auth_header[@]}" \
    "https://api.github.com/repos/anomalyco/opencode/releases/tags/v${version}")"
  url="$(jq -r --arg asset "${asset}" \
    '.assets[] | select(.name == $asset) | .browser_download_url // empty' <<< "${release}")"
  digest="$(jq -r --arg asset "${asset}" \
    '.assets[] | select(.name == $asset) | .digest // empty' <<< "${release}" | sed 's/^sha256://')"
  if [[ -z "${url}" || -z "${digest}" ]]; then
    echo "::error::Failed to resolve release asset '${asset}' (with digest) for opencode ${version}."
    return 1
  fi

  bin_dir="${HOME}/.opencode/bin"
  mkdir -p "${bin_dir}"
  archive="$(mktemp)"
  # The RETURN trap persists after this function exits, so it must disarm
  # itself; otherwise it fires on the caller's return with archive unbound.
  trap 'rm -f "${archive:-}"; trap - RETURN' RETURN
  curl -fsSL -o "${archive}" "${url}"
  if command -v sha256sum > /dev/null 2>&1; then
    echo "${digest}  ${archive}" | sha256sum -c -
  else
    echo "${digest}  ${archive}" | shasum -a 256 -c -
  fi

  case "${asset}" in
    *.tar.gz)
      tar -xzf "${archive}" -C "${bin_dir}" "${binary}"
      ;;
    *.zip)
      unzip -o -q "${archive}" -d "${bin_dir}" "${binary}"
      ;;
  esac
  chmod 755 "${bin_dir}/${binary}"
  echo "::notice::Installed opencode ${version} (${asset}, sha256 verified)"
}

_opencode_install_main() {
  opencode_install \
    "${OPENCODE_VERSION:?OPENCODE_VERSION is required}" \
    "${RUNNER_OS:?RUNNER_OS is required}" \
    "${RUNNER_ARCH:?RUNNER_ARCH is required}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  _opencode_install_main
fi
