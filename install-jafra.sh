#!/usr/bin/env bash
# install-jafra.sh — Build/load images and deploy Jafra to Kind or OpenShift.
#
# Usage:
#   ./install-jafra.sh                                    # Kind: build/load/deploy
#   ./install-jafra.sh --target openshift                 # OCP: SCC + deploy (pull from registry)
#   ./install-jafra.sh --target openshift --deploy-only   # OCP: manifests only
#   ./install-jafra.sh --force-build
#   ./install-jafra.sh --install-cert-manager
#   ./install-jafra.sh --teardown
#
# Environment:
#   JAFRA_TARGET      kind | openshift (default: kind)
#   JAFRA_NAMESPACE   Platform namespace (default: jafra-system; manifests pinned)
#   KIND_CLUSTER      Kind cluster name (default: jafra; kind target only)
#   JAFRA_VERSION     Image tag (default: 0.0.2)
#   JAFRA_REGISTRY    Image registry prefix (default: quay.io/bharathappali)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"
# shellcheck source=scripts/lib/cert-manager.sh
source "${SCRIPT_DIR}/scripts/lib/cert-manager.sh"
# shellcheck source=scripts/lib/deploy-jafra.sh
source "${SCRIPT_DIR}/scripts/lib/deploy-jafra.sh"
# shellcheck source=scripts/lib/target-kind.sh
source "${SCRIPT_DIR}/scripts/lib/target-kind.sh"
# shellcheck source=scripts/lib/target-openshift.sh
source "${SCRIPT_DIR}/scripts/lib/target-openshift.sh"

FORCE_BUILD=false
DEPLOY_ONLY=false
INSTALL_CERT_MANAGER=false
TEARDOWN=false

usage() {
  cat <<EOF
Usage: $0 [options]

Targets:
  --target kind         Build/load images into Kind and deploy (default)
  --target openshift    Deploy to OpenShift (registry pull, SCC bindings)

Options:
  (no args)             Target-specific install (see below)
  --force-build         Kind only: rebuild all images, then load + deploy
  --deploy-only         Skip image build/load, apply manifests (+ OCP SCC platform)
  --install-cert-manager  Install cert-manager first, then continue
  --teardown            Remove Jafra resources from the cluster
  --help, -h            Show this help

Kind flow (default):
  Check/build images → kind load → deploy → switch agent to gRPC

OpenShift flow:
  Apply platform SCC bindings → deploy → verify

Environment:
  JAFRA_TARGET        kind | openshift (default: kind)
  JAFRA_NAMESPACE     Platform namespace (default: jafra-system)
  KIND_CLUSTER        Kind cluster name (default: jafra)
  JAFRA_VERSION       Image tag (default: ${VERSION})
  JAFRA_REGISTRY      Registry prefix (default: ${JAFRA_REGISTRY})

OpenShift permissions: see deploy/openshift/README.md
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target)
        [[ $# -ge 2 ]] || { error "--target requires kind or openshift"; exit 1; }
        JAFRA_TARGET="$2"
        shift 2
        ;;
      --force-build)
        FORCE_BUILD=true
        shift
        ;;
      --deploy-only)
        DEPLOY_ONLY=true
        shift
        ;;
      --install-cert-manager)
        INSTALL_CERT_MANAGER=true
        shift
        ;;
      --teardown)
        TEARDOWN=true
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

  validate_target
  require_namespace_matches_manifests

  if [[ "${JAFRA_TARGET}" != "kind" && "${FORCE_BUILD}" == "true" ]]; then
    error "--force-build is only supported with --target kind"
    exit 1
  fi

  if [[ "${TEARDOWN}" == "true" && ( "${DEPLOY_ONLY}" == "true" || "${FORCE_BUILD}" == "true" || "${INSTALL_CERT_MANAGER}" == "true" ) ]]; then
    error "--teardown cannot be combined with install options"
    exit 1
  fi
}

check_prerequisites() {
  case "${JAFRA_TARGET}" in
    kind) check_kind_prerequisites ;;
    openshift) check_openshift_prerequisites ;;
  esac
}

target_pre_deploy() {
  case "${JAFRA_TARGET}" in
    kind) kind_pre_deploy ;;
    openshift) openshift_pre_deploy ;;
  esac
}

target_prepare_images() {
  if [[ "${DEPLOY_ONLY}" == "true" ]]; then
    info "Skipping image build/load (--deploy-only)"
    return
  fi

  case "${JAFRA_TARGET}" in
    kind)
      ensure_kind_images "${FORCE_BUILD}"
      load_kind_images
      ;;
    openshift)
      step "Using registry images (no kind load)"
      info "Controller: ${CONTROLLER_IMAGE}"
      info "Agent:      ${AGENT_IMAGE}"
      info "Analyzer:   ${ANALYZER_IMAGE}"
      info "Ensure the cluster can pull these images from ${JAFRA_REGISTRY}."
      ;;
  esac
}

main() {
  parse_args "$@"

  check_prerequisites

  if [[ "${TEARDOWN}" == "true" ]]; then
    teardown_jafra
    exit 0
  fi

  if [[ "${INSTALL_CERT_MANAGER}" == "true" ]]; then
    install_cert_manager
  fi

  target_prepare_images
  target_pre_deploy
  deploy_all
  verify_jafra
}

main "$@"
