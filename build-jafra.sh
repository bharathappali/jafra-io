#!/usr/bin/env bash
# build-jafra.sh — Build Jafra images with Podman for Linux amd64 and arm64.
#
# Compilers run on the Podman host/VM architecture (BUILDPLATFORM). Final
# images are linux/amd64 and/or linux/arm64. This avoids qemu-user, which
# SIGSEGVs rustc when emulating amd64 on Apple Silicon.
#
# Usage:
#   ./build-jafra.sh
#   ./build-jafra.sh --platform linux/amd64
#   ./build-jafra.sh --platform linux/arm64
#   ./build-jafra.sh --multi-platform
#   ./build-jafra.sh --component analyzer
#   ./build-jafra.sh --no-cache --push
#
# Environment:
#   JAFRA_VERSION    Image tag (default: 0.1.0)
#   JAFRA_REGISTRY   Image registry prefix (default: quay.io/bharathappali)
#   JAFRA_PLATFORM   Default --platform (default: linux/amd64)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${JAFRA_VERSION:-0.1.0}"
REGISTRY="${JAFRA_REGISTRY:-quay.io/bharathappali}"
PLATFORM="${JAFRA_PLATFORM:-linux/amd64}"
MULTI_ARCH_PLATFORMS="linux/amd64,linux/arm64"

NO_CACHE=false
PUSH=false
MULTI_PLATFORM=false
COMPONENT="all"
PLATFORMS=""

CONTROLLER_IMAGE="${REGISTRY}/jafra-controller:${VERSION}"
AGENT_IMAGE="${REGISTRY}/jafra-agent:${VERSION}"
ANALYZER_IMAGE="${REGISTRY}/jafra-analyzer:${VERSION}"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[jafra]${NC} $*"; }
warn()  { echo -e "${YELLOW}[jafra]${NC} $*"; }
error() { echo -e "${RED}[jafra]${NC} $*" >&2; }
step()  { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

usage() {
  cat <<EOF
Usage: $0 [options]

Build Jafra container images with Podman for Linux amd64 and arm64.

Options:
  --platform <list>     Comma-separated platforms (default: linux/amd64)
                        Examples: linux/amd64  linux/arm64
  --multi-platform      Build linux/amd64 and linux/arm64.
                        Tags :${VERSION}-amd64 and :${VERSION}-arm64 per image,
                        and :${VERSION} as a manifest list with both arches.
  --component <name>    controller | agent | analyzer | all (default: all)
  --no-cache            Pass --no-cache to podman build
  --push                Push per-arch tags and the version manifest
  --help, -h            Show this help

Environment:
  JAFRA_VERSION         Image tag (default: 0.1.0)
  JAFRA_REGISTRY        Registry prefix (default: quay.io/bharathappali)
  JAFRA_PLATFORM        Default --platform (default: linux/amd64)

Images:
  <name>:${VERSION}-amd64              linux/amd64
  <name>:${VERSION}-arm64              linux/arm64
  <name>:${VERSION}                    both arches when --multi-platform
                                       (single arch otherwise)

Build contexts:
  controller  -f jafra-controller/Dockerfile  jafra-controller/
  agent       -f jafra-agent/Dockerfile       repo root (needs contracts/)
  analyzer    -f jafra-analyzer/Dockerfile    repo root (needs contracts/)
EOF
}

require_podman() {
  if ! command -v podman >/dev/null 2>&1; then
    error "podman is required but not found"
    error "Install Podman, then re-run: $0"
    exit 1
  fi
}

host_arch() {
  local m
  m="$(uname -m)"
  case "${m}" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "${m}" ;;
  esac
}

platform_arch() {
  case "$1" in
    linux/amd64) echo "amd64" ;;
    linux/arm64|linux/arm64/v8) echo "arm64" ;;
    *) echo "" ;;
  esac
}

normalize_platforms() {
  local raw="$1"
  local out=""
  local p arch
  raw="${raw//,/ }"
  for p in ${raw}; do
    arch="$(platform_arch "${p}")"
    if [[ -z "${arch}" ]]; then
      error "Unsupported platform '${p}'. Use linux/amd64 and/or linux/arm64."
      exit 1
    fi
    # Canonicalize linux/arm64/v8 -> linux/arm64
    if [[ "${p}" == linux/arm64/v8 ]]; then
      p="linux/arm64"
    fi
    case " ${out} " in
      *" ${p} "*) ;;
      *) out="${out} ${p}" ;;
    esac
  done
  PLATFORMS="${out# }"
  if [[ -z "${PLATFORMS}" ]]; then
    error "No platforms selected"
    exit 1
  fi
}

platform_count() {
  local n=0 p
  for p in ${PLATFORMS}; do
    n=$((n + 1))
  done
  echo "${n}"
}

remove_local_ref() {
  local ref="$1"
  podman manifest exists "${ref}" >/dev/null 2>&1 && podman manifest rm "${ref}" >/dev/null 2>&1 || true
  podman image exists "${ref}" >/dev/null 2>&1 && podman rmi -f "${ref}" >/dev/null 2>&1 || true
}

build_platform() {
  local name="$1"
  local image="$2"
  local dockerfile="$3"
  local context="$4"
  local plat="$5"
  local arch tagged buildplat

  arch="$(platform_arch "${plat}")"
  tagged="${image}-${arch}"
  buildplat="linux/$(host_arch)"

  step "Building ${name} (${plat})"
  info "Image:         ${tagged}"
  info "Manifest tag:  ${image}"
  info "Dockerfile:    ${dockerfile}"
  info "Context:       ${context}"
  info "BUILDPLATFORM: ${buildplat}"

  # macOS Bash 3.2 + set -u: never expand empty arrays.
  podman build \
    --platform "${plat}" \
    --build-arg BUILDPLATFORM="${buildplat}" \
    --build-arg TARGETPLATFORM="${plat}" \
    -f "${dockerfile}" \
    -t "${tagged}" \
    ${NO_CACHE:+--no-cache} \
    "${context}"

  info "Built ${tagged}"
  podman image inspect "${tagged}" --format '{{.Os}}/{{.Architecture}}' || true
}

assemble_manifest() {
  local image="$1"
  local plat arch tagged count

  count="$(platform_count)"
  if [[ "${count}" -eq 1 ]]; then
    plat="${PLATFORMS}"
    arch="$(platform_arch "${plat}")"
    tagged="${image}-${arch}"
    info "Single platform: tagging ${tagged} as ${image}"
    podman tag "${tagged}" "${image}"
    return
  fi

  step "Creating multi-arch manifest ${image}"
  info "Includes: ${PLATFORMS}"
  remove_local_ref "${image}"
  podman manifest create "${image}"
  for plat in ${PLATFORMS}; do
    arch="$(platform_arch "${plat}")"
    tagged="${image}-${arch}"
    info "Adding ${tagged} (${plat})"
    podman manifest add "${image}" "${tagged}"
  done
  info "Manifest ${image} ready (linux/amd64 + linux/arm64)"
}

push_image() {
  local image="$1"
  local plat arch tagged count

  count="$(platform_count)"
  for plat in ${PLATFORMS}; do
    arch="$(platform_arch "${plat}")"
    tagged="${image}-${arch}"
    step "Pushing ${tagged}"
    podman push "${tagged}"
  done

  step "Pushing ${image}"
  if [[ "${count}" -gt 1 ]]; then
    podman manifest push --all "${image}"
  else
    podman push "${image}"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --platform)
        [[ $# -ge 2 ]] || { error "--platform requires a value"; exit 1; }
        PLATFORM="$2"
        shift 2
        ;;
      --multi-platform|--multi-arch)
        MULTI_PLATFORM=true
        shift
        ;;
      --component)
        [[ $# -ge 2 ]] || { error "--component requires a value"; exit 1; }
        COMPONENT="$2"
        shift 2
        ;;
      --no-cache)
        NO_CACHE=true
        shift
        ;;
      --push)
        PUSH=true
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        error "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
  done

  case "${COMPONENT}" in
    all|controller|agent|analyzer) ;;
    *)
      error "Unknown component '${COMPONENT}' (use controller, agent, analyzer, or all)"
      exit 1
      ;;
  esac
}

main() {
  parse_args "$@"
  require_podman

  if [[ "${MULTI_PLATFORM}" == "true" ]]; then
    if [[ "${PLATFORM}" != "linux/amd64" && "${PLATFORM}" != "${MULTI_ARCH_PLATFORMS}" ]]; then
      warn "--multi-platform overrides --platform ${PLATFORM}"
    fi
    PLATFORM="${MULTI_ARCH_PLATFORMS}"
  fi

  normalize_platforms "${PLATFORM}"

  info "Registry:      ${REGISTRY}"
  info "Version:       ${VERSION}"
  info "Platforms:     ${PLATFORMS}"
  info "Component:     ${COMPONENT}"
  info "BUILDPLATFORM: linux/$(host_arch)"

  local names=""
  if [[ "${COMPONENT}" == "all" || "${COMPONENT}" == "controller" ]]; then
    for plat in ${PLATFORMS}; do
      build_platform \
        "jafra-controller" \
        "${CONTROLLER_IMAGE}" \
        "${SCRIPT_DIR}/jafra-controller/Dockerfile" \
        "${SCRIPT_DIR}/jafra-controller" \
        "${plat}"
    done
    assemble_manifest "${CONTROLLER_IMAGE}"
    names="${names} ${CONTROLLER_IMAGE}"
  fi

  if [[ "${COMPONENT}" == "all" || "${COMPONENT}" == "agent" ]]; then
    for plat in ${PLATFORMS}; do
      build_platform \
        "jafra-agent" \
        "${AGENT_IMAGE}" \
        "${SCRIPT_DIR}/jafra-agent/Dockerfile" \
        "${SCRIPT_DIR}" \
        "${plat}"
    done
    assemble_manifest "${AGENT_IMAGE}"
    names="${names} ${AGENT_IMAGE}"
  fi

  if [[ "${COMPONENT}" == "all" || "${COMPONENT}" == "analyzer" ]]; then
    for plat in ${PLATFORMS}; do
      build_platform \
        "jafra-analyzer" \
        "${ANALYZER_IMAGE}" \
        "${SCRIPT_DIR}/jafra-analyzer/Dockerfile" \
        "${SCRIPT_DIR}" \
        "${plat}"
    done
    assemble_manifest "${ANALYZER_IMAGE}"
    names="${names} ${ANALYZER_IMAGE}"
  fi

  if [[ "${PUSH}" == "true" ]]; then
    for image in ${names}; do
      push_image "${image}"
    done
  fi

  step "Done"
  for image in ${names}; do
    info "${image}"
    for plat in ${PLATFORMS}; do
      info "  ${image}-$(platform_arch "${plat}")  [${plat}]"
    done
    if [[ "$(platform_count)" -gt 1 ]]; then
      info "  ${image}  [manifest: ${PLATFORMS}]"
    fi
  done
}

main "$@"
