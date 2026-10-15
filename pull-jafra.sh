#!/usr/bin/env bash
# pull-jafra.sh — Pull published images, load them into Kind, and deploy Jafra.
#
# Unlike install-jafra.sh (which builds from source), this script only pulls
# from the registry. Use it when images are already published.
#
# Usage:
#   ./pull-jafra.sh                         # pull missing images, load into Kind, deploy
#   ./pull-jafra.sh --force-pull            # always pull fresh images, then load + deploy
#   ./pull-jafra.sh --deploy-only           # skip pull/load, just apply manifests
#   ./pull-jafra.sh --install-cert-manager  # install cert-manager first, then continue
#   ./pull-jafra.sh --mcp                  # same as default, plus MCP server
#   ./pull-jafra.sh --force-pull --mcp     # force-pull Jafra + MCP, then deploy all
#   ./pull-jafra.sh --teardown              # delete Jafra (+ cert-manager if we installed it)
#   ./pull-jafra.sh --teardown --uninstall-cert-manager  # also remove cert-manager
#
#   JAFRA_REGISTRY=quay.io/bharathappali JAFRA_VERSION=0.0.3-dev ./pull-jafra.sh --force-pull
#
# Prerequisites:
#   - kind cluster named "jafra" (or set KIND_CLUSTER)
#   - docker, kubectl (with Kustomize), kind
#   - network access to the registry (for pull)
#   - cert-manager already installed, or pass --install-cert-manager

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAFRA_TARGET=kind
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"
# shellcheck source=scripts/lib/cert-manager.sh
source "${SCRIPT_DIR}/scripts/lib/cert-manager.sh"
# shellcheck source=scripts/lib/deploy-jafra.sh
source "${SCRIPT_DIR}/scripts/lib/deploy-jafra.sh"
# shellcheck source=scripts/lib/target-kind.sh
source "${SCRIPT_DIR}/scripts/lib/target-kind.sh"

MCP_VERSION="${MCP_VERSION:-0.1.0}"
MCP_MANIFEST="${SCRIPT_DIR}/Async-MCP/manifests/async-profiler-mcp-server-kind.yaml"
CERT_MANAGER_MANIFEST="${CERT_MANAGER_MANIFEST:-https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml}"
# Namespace label set when this script installs cert-manager (used by --teardown).
CERT_MANAGER_OWNED_LABEL="jafra.io/installed-by"
CERT_MANAGER_OWNED_VALUE="pull-jafra"

MCP_IMAGE="${MCP_IMAGE:-quay.io/khansaad/async-profiler-mcp-server:${MCP_VERSION}}"

FORCE_PULL=false
DEPLOY_ONLY=false
INSTALL_CERT_MANAGER=false
TEARDOWN=false
WITH_MCP=false
UNINSTALL_CERT_MANAGER=false

pull_image_if_needed() {
  local image="$1"
  local force="$2"

  if [[ "$force" == "true" ]] || ! image_exists "$image"; then
    if [[ "$force" == "true" ]]; then
      info "Force pulling ${image}..."
    else
      warn "${image} not found locally, pulling..."
    fi
    docker pull "$image"
  else
    info "${image} already exists locally, skipping pull"
  fi
}

ensure_images() {
  local force="${1:-false}"

  resolve_component_versions
  step "Pulling container images (force-pull=${force})"
  info "Registry: ${REGISTRY}"
  info "Version:  controller=${CONTROLLER_TAG} agent=${AGENT_TAG} analyzer=${ANALYZER_TAG}"

  pull_image_if_needed "${CONTROLLER_IMAGE}" "$force"
  pull_image_if_needed "${AGENT_IMAGE}" "$force"
  pull_image_if_needed "${ANALYZER_IMAGE}" "$force"

  if [[ "${WITH_MCP}" == "true" ]]; then
    pull_image_if_needed "${MCP_IMAGE}" "$force"
  fi
}

load_images() {
  resolve_component_versions
  step "Loading images into Kind cluster '${KIND_CLUSTER}'"

  kind load docker-image "${CONTROLLER_IMAGE}" --name "${KIND_CLUSTER}"
  kind load docker-image "${AGENT_IMAGE}" --name "${KIND_CLUSTER}"
  kind load docker-image "${ANALYZER_IMAGE}" --name "${KIND_CLUSTER}"

  if [[ "${WITH_MCP}" == "true" ]]; then
    kind load docker-image "${MCP_IMAGE}" --name "${KIND_CLUSTER}"
  fi

  info "All images loaded"
}

cert_manager_owned_by_script() {
  local value=""
  value="$(kubectl_cmd get namespace cert-manager \
    -o go-template="{{index .metadata.labels \"${CERT_MANAGER_OWNED_LABEL}\"}}" 2>/dev/null || true)"
  [[ "${value}" == "${CERT_MANAGER_OWNED_VALUE}" ]]
}

mark_cert_manager_owned() {
  kubectl_cmd label namespace cert-manager \
    "${CERT_MANAGER_OWNED_LABEL}=${CERT_MANAGER_OWNED_VALUE}" \
    --overwrite >/dev/null
  info "Marked cert-manager as installed by pull-jafra (label ${CERT_MANAGER_OWNED_LABEL}=${CERT_MANAGER_OWNED_VALUE})"
}

uninstall_cert_manager() {
  step "Uninstalling cert-manager (installed by this script)"

  if ! kubectl_cmd get namespace cert-manager &>/dev/null && ! cert_manager_crds_ready; then
    info "cert-manager already gone, skipping"
    return
  fi

  warn "Deleting cert-manager manifests..."
  kubectl_cmd delete -f "${CERT_MANAGER_MANIFEST}" --ignore-not-found 2>/dev/null || true

  kubectl_cmd delete namespace cert-manager --ignore-not-found --wait=false 2>/dev/null || true
  info "cert-manager uninstall requested"
}

install_cert_manager_pull() {
  if cert_manager_installed; then
    info "cert-manager is already installed, skipping"
    if ! cert_manager_owned_by_script; then
      info "Not marking ownership — cert-manager was not installed by this run"
    fi
    return
  fi

  install_cert_manager
  mark_cert_manager_owned
}

teardown_pull() {
  # Do not apply the full Kind MCP yaml here — it includes the jafra-system
  # Namespace and would cascade-delete the whole stack before other steps run.
  warn "Deleting MCP server (if present)..."
  kubectl_cmd delete deploy,svc async-profiler-mcp-server -n "${JAFRA_NAMESPACE}" --ignore-not-found 2>/dev/null || true

  teardown_jafra

  if cert_manager_owned_by_script || [[ "${UNINSTALL_CERT_MANAGER}" == "true" ]]; then
    uninstall_cert_manager
  else
    info "Leaving cert-manager installed (not marked as installed by this script)."
    info "To remove it: $0 --teardown --uninstall-cert-manager"
  fi
}

deploy_mcp() {
  step "Deploying async-profiler MCP server"

  if [[ ! -f "${MCP_MANIFEST}" ]]; then
    error "MCP Kind manifest missing: ${MCP_MANIFEST}"
    error "Clone Async-MCP into the repo root first:"
    error "  git clone https://github.com/khansaad/Async-MCP.git Async-MCP"
    exit 1
  fi

  if ! kubectl_cmd get svc jafra-analyzer -n "${JAFRA_NAMESPACE}" &>/dev/null; then
    error "jafra-analyzer Service not found in ${JAFRA_NAMESPACE}."
    error "Deploy the Jafra stack first (or run without --deploy-only)."
    exit 1
  fi

  info "Manifest: ${MCP_MANIFEST}"
  info "Image:    ${MCP_IMAGE}"
  info "JAFRA_ANALYZER_URL=http://jafra-analyzer.${JAFRA_NAMESPACE}.svc.cluster.local:8080"

  kubectl_cmd apply -f "${MCP_MANIFEST}"
  kubectl_cmd set image deployment/async-profiler-mcp-server \
    -n "${JAFRA_NAMESPACE}" "mcp-server=${MCP_IMAGE}"

  info "Waiting for MCP server rollout..."
  kubectl_cmd rollout status deployment/async-profiler-mcp-server \
    -n "${JAFRA_NAMESPACE}" --timeout=180s

  info "MCP server ready"
}

deploy_all_pull() {
  deploy_all

  if [[ "${WITH_MCP}" == "true" ]]; then
    deploy_mcp
  fi
}

verify_pull() {
  verify_jafra

  if [[ "${WITH_MCP}" == "true" ]]; then
    info "MCP server:"
    kubectl_cmd get deploy,svc async-profiler-mcp-server -n "${JAFRA_NAMESPACE}" 2>/dev/null || warn "MCP not found"
    echo ""
    info "MCP connects to analyzer at:"
    info "  http://jafra-analyzer.${JAFRA_NAMESPACE}.svc.cluster.local:8080"
    info ""
    info "Port-forward MCP for local agents / MCP Inspector:"
    info "  kubectl -n ${JAFRA_NAMESPACE} port-forward svc/async-profiler-mcp-server 18081:8080"
    info "  # Streamable HTTP: http://127.0.0.1:18081/mcp/"
    info "  # Optional smoke test (from Async-MCP clone):"
    info "  #   python3 Async-MCP/smoke_test.py http://127.0.0.1:18081"
    echo ""
  fi
}

usage() {
  resolve_component_versions
  echo "Usage: $0 [options]"
  echo ""
  echo "  (no args)              Pull missing images from quay, load into Kind, deploy"
  echo "  --force-pull           Always docker pull all images, then load + deploy"
  echo "  --install-cert-manager Install cert-manager first, then continue install"
  echo "  --deploy-only          Skip pull/load, just apply Kubernetes manifests"
  echo "  --mcp                  Also pull/load/deploy async-profiler MCP server"
  echo "                         (configured to call jafra-analyzer in-cluster)"
  echo "  --teardown             Remove all Jafra resources from the cluster (incl. MCP)"
  echo "  --uninstall-cert-manager  With --teardown: also remove cert-manager even if"
  echo "                         it was not marked as installed by this script"
  echo "  --help                 Show this help"
  echo ""
  echo "Examples:"
  echo "  $0 --mcp"
  echo "  $0 --force-pull --mcp"
  echo "  JAFRA_REGISTRY=quay.io/bharathappali JAFRA_VERSION=0.0.3-dev $0 --force-pull"
  echo "  $0 --deploy-only --mcp"
  echo "  $0 --install-cert-manager --mcp"
  echo "  $0 --teardown"
  echo "  $0 --teardown --uninstall-cert-manager"
  echo ""
  echo "This script pulls published images. To build from source instead, use ./install-jafra.sh"
  echo ""
  echo "Environment:"
  echo "  KIND_CLUSTER    Kind cluster name (default: jafra)"
  echo "  JAFRA_REGISTRY  Image registry prefix (default: quay.io/bharathappali)"
  echo "  JAFRA_VERSION   Jafra image tag (default: 0.0.2)"
  echo "  MCP_VERSION     MCP image tag (default: 0.1.0)"
  echo "  MCP_IMAGE        Full MCP image override"
  echo ""
  echo "Notes:"
  echo "  --install-cert-manager labels namespace/cert-manager so a later"
  echo "  --teardown will uninstall cert-manager automatically."
  echo "  Pre-existing cert-manager is left alone unless you pass"
  echo "  --teardown --uninstall-cert-manager."
  echo "  Workload images are set via Kustomize before apply (see deploy/kustomize/)."
  echo ""
  echo "Images:"
  echo "  ${CONTROLLER_IMAGE}"
  echo "  ${AGENT_IMAGE}"
  echo "  ${ANALYZER_IMAGE}"
  echo "  ${MCP_IMAGE}  (only with --mcp)"
}

parse_args() {
  if [[ $# -eq 0 ]]; then
    return
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --teardown)
        TEARDOWN=true
        shift
        ;;
      --uninstall-cert-manager)
        UNINSTALL_CERT_MANAGER=true
        shift
        ;;
      --install-cert-manager)
        INSTALL_CERT_MANAGER=true
        shift
        ;;
      --deploy-only)
        DEPLOY_ONLY=true
        shift
        ;;
      --force-pull)
        FORCE_PULL=true
        shift
        ;;
      --mcp)
        WITH_MCP=true
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        error "Unknown option: $1"
        echo "Run '$0 --help' for usage"
        exit 1
        ;;
    esac
  done

  if [[ "${UNINSTALL_CERT_MANAGER}" == "true" && "${TEARDOWN}" != "true" ]]; then
    error "--uninstall-cert-manager only works with --teardown"
    error "  Example: $0 --teardown --uninstall-cert-manager"
    exit 1
  fi

  if [[ "${TEARDOWN}" == "true" && ( "${DEPLOY_ONLY}" == "true" || "${FORCE_PULL}" == "true" || "${INSTALL_CERT_MANAGER}" == "true" ) ]]; then
    error "--teardown cannot be combined with install options"
    exit 1
  fi

  if [[ "${DEPLOY_ONLY}" == "true" && "${FORCE_PULL}" == "true" ]]; then
    error "--deploy-only and --force-pull cannot be combined"
    exit 1
  fi
}

main() {
  parse_args "$@"
  check_kind_prerequisites

  if [[ "${TEARDOWN}" == "true" ]]; then
    teardown_pull
    exit 0
  fi

  if [[ "${INSTALL_CERT_MANAGER}" == "true" ]]; then
    install_cert_manager_pull
  fi

  if [[ "${DEPLOY_ONLY}" != "true" ]]; then
    ensure_images "${FORCE_PULL}"
    load_images
  fi

  deploy_all_pull
  verify_pull
}

main "$@"
