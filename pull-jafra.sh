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
# Prerequisites:
#   - kind cluster named "jafra" (or set KIND_CLUSTER)
#   - docker, kubectl, kind
#   - network access to quay.io (for pull)
#   - cert-manager already installed, or pass --install-cert-manager

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIND_CLUSTER="${KIND_CLUSTER:-jafra}"
VERSION="${JAFRA_VERSION:-0.1.0}"
MCP_VERSION="${MCP_VERSION:-0.1.0}"
MCP_MANIFEST="${SCRIPT_DIR}/Async-MCP/manifests/async-profiler-mcp-server-kind.yaml"
CERT_MANAGER_MANIFEST="${CERT_MANAGER_MANIFEST:-https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml}"
# Namespace label set when this script installs cert-manager (used by --teardown).
CERT_MANAGER_OWNED_LABEL="jafra.io/installed-by"
CERT_MANAGER_OWNED_VALUE="pull-jafra"

CONTROLLER_IMAGE="quay.io/causa-ai-hub/jafra-controller:${VERSION}"
AGENT_IMAGE="quay.io/causa-ai-hub/jafra-agent:${VERSION}"
ANALYZER_IMAGE="quay.io/causa-ai-hub/jafra-analyzer:${VERSION}"
MCP_IMAGE="${MCP_IMAGE:-quay.io/khansaad/async-profiler-mcp-server:${MCP_VERSION}}"

FORCE_PULL=false
DEPLOY_ONLY=false
INSTALL_CERT_MANAGER=false
TEARDOWN=false
WITH_MCP=false
UNINSTALL_CERT_MANAGER=false

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[jafra]${NC} $*"; }
warn()  { echo -e "${YELLOW}[jafra]${NC} $*"; }
error() { echo -e "${RED}[jafra]${NC} $*" >&2; }
step()  { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

image_exists() {
  docker image inspect "$1" &>/dev/null
}

cert_manager_crds_ready() {
  kubectl get crd certificates.cert-manager.io &>/dev/null &&
    kubectl get crd issuers.cert-manager.io &>/dev/null
}

cert_manager_installed() {
  cert_manager_crds_ready &&
    kubectl get namespace cert-manager &>/dev/null &&
    kubectl get deployment cert-manager -n cert-manager &>/dev/null &&
    kubectl get deployment cert-manager-webhook -n cert-manager &>/dev/null &&
    kubectl get deployment cert-manager-cainjector -n cert-manager &>/dev/null
}

require_cert_manager() {
  if cert_manager_installed; then
    return 0
  fi

  error "cert-manager is required but not installed (Issuer/Certificate CRDs missing)."
  error "Re-run with cert-manager install:"
  error "  $0 --install-cert-manager"
  error "Or install it manually, then continue with --deploy-only:"
  error "  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml"
  exit 1
}

check_prerequisites() {
  local missing=0
  for cmd in docker kubectl kind; do
    if ! command -v "$cmd" &>/dev/null; then
      error "$cmd is required but not found"
      missing=1
    fi
  done
  if [[ $missing -ne 0 ]]; then
    exit 1
  fi

  if ! kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER}$"; then
    error "Kind cluster '${KIND_CLUSTER}' not found. Create it first:"
    error "  kind create cluster --name ${KIND_CLUSTER}"
    exit 1
  fi

  kubectl config use-context "kind-${KIND_CLUSTER}" &>/dev/null || true
}

teardown() {
  step "Tearing down Jafra ecosystem"

  # Do not apply the full Kind MCP yaml here — it includes the jafra-system
  # Namespace and would cascade-delete the whole stack before other steps run.
  warn "Deleting MCP server (if present)..."
  kubectl delete deploy,svc async-profiler-mcp-server -n jafra-system --ignore-not-found 2>/dev/null || true

  warn "Deleting webhook..."
  kubectl delete -f "${SCRIPT_DIR}/deploy/controller/webhook.yaml" --ignore-not-found 2>/dev/null || true

  warn "Deleting agent..."
  kubectl delete -f "${SCRIPT_DIR}/deploy/agent/daemonset.yaml" --ignore-not-found 2>/dev/null || true
  kubectl delete -f "${SCRIPT_DIR}/deploy/agent/rbac.yaml" --ignore-not-found 2>/dev/null || true

  warn "Deleting analyzer..."
  kubectl delete -f "${SCRIPT_DIR}/deploy/analyzer/deployment.yaml" --ignore-not-found 2>/dev/null || true

  warn "Deleting controller..."
  kubectl delete -f "${SCRIPT_DIR}/deploy/controller/deployment.yaml" --ignore-not-found 2>/dev/null || true
  kubectl delete -f "${SCRIPT_DIR}/deploy/controller/service.yaml" --ignore-not-found 2>/dev/null || true
  kubectl delete -f "${SCRIPT_DIR}/deploy/controller/certificate.yaml" --ignore-not-found 2>/dev/null || true
  kubectl delete -f "${SCRIPT_DIR}/deploy/controller/rbac.yaml" --ignore-not-found 2>/dev/null || true

  warn "Deleting namespace..."
  kubectl delete namespace jafra-system --ignore-not-found 2>/dev/null || true

  if cert_manager_owned_by_script || [[ "${UNINSTALL_CERT_MANAGER}" == "true" ]]; then
    uninstall_cert_manager
  else
    info "Leaving cert-manager installed (not marked as installed by this script)."
    info "To remove it: $0 --teardown --uninstall-cert-manager"
  fi

  info "Teardown complete"
}

cert_manager_owned_by_script() {
  local value=""
  value="$(kubectl get namespace cert-manager \
    -o go-template="{{index .metadata.labels \"${CERT_MANAGER_OWNED_LABEL}\"}}" 2>/dev/null || true)"
  [[ "${value}" == "${CERT_MANAGER_OWNED_VALUE}" ]]
}

mark_cert_manager_owned() {
  kubectl label namespace cert-manager \
    "${CERT_MANAGER_OWNED_LABEL}=${CERT_MANAGER_OWNED_VALUE}" \
    --overwrite >/dev/null
  info "Marked cert-manager as installed by pull-jafra (label ${CERT_MANAGER_OWNED_LABEL}=${CERT_MANAGER_OWNED_VALUE})"
}

uninstall_cert_manager() {
  step "Uninstalling cert-manager (installed by this script)"

  if ! kubectl get namespace cert-manager &>/dev/null && ! cert_manager_crds_ready; then
    info "cert-manager already gone, skipping"
    return
  fi

  warn "Deleting cert-manager manifests..."
  kubectl delete -f "${CERT_MANAGER_MANIFEST}" --ignore-not-found 2>/dev/null || true

  # CRDs / namespace can linger briefly; best-effort cleanup.
  kubectl delete namespace cert-manager --ignore-not-found --wait=false 2>/dev/null || true
  info "cert-manager uninstall requested"
}

install_cert_manager() {
  step "Installing cert-manager"

  if cert_manager_installed; then
    info "cert-manager is already installed, skipping"
    if ! cert_manager_owned_by_script; then
      info "Not marking ownership — cert-manager was not installed by this run"
    fi
    return
  fi

  info "Applying cert-manager manifests..."
  kubectl apply -f "${CERT_MANAGER_MANIFEST}"

  info "Waiting for cert-manager CRDs..."
  kubectl wait --for=condition=Established crd/certificates.cert-manager.io --timeout=120s
  kubectl wait --for=condition=Established crd/issuers.cert-manager.io --timeout=120s

  info "Waiting for cert-manager deployments..."
  kubectl rollout status deployment/cert-manager -n cert-manager --timeout=180s
  kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=180s
  kubectl rollout status deployment/cert-manager-cainjector -n cert-manager --timeout=180s

  mark_cert_manager_owned
  info "cert-manager is ready"
}

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

  step "Pulling container images (force-pull=${force})"

  pull_image_if_needed "${CONTROLLER_IMAGE}" "$force"
  pull_image_if_needed "${AGENT_IMAGE}" "$force"
  pull_image_if_needed "${ANALYZER_IMAGE}" "$force"

  if [[ "${WITH_MCP}" == "true" ]]; then
    pull_image_if_needed "${MCP_IMAGE}" "$force"
  fi
}

load_images() {
  step "Loading images into Kind cluster '${KIND_CLUSTER}'"

  kind load docker-image "${CONTROLLER_IMAGE}" --name "${KIND_CLUSTER}"
  kind load docker-image "${AGENT_IMAGE}" --name "${KIND_CLUSTER}"
  kind load docker-image "${ANALYZER_IMAGE}" --name "${KIND_CLUSTER}"

  if [[ "${WITH_MCP}" == "true" ]]; then
    kind load docker-image "${MCP_IMAGE}" --name "${KIND_CLUSTER}"
  fi

  info "All images loaded"
}

deploy_controller() {
  step "Deploying jafra-controller"

  require_cert_manager

  info "Creating namespace..."
  kubectl apply -f "${SCRIPT_DIR}/deploy/controller/namespace.yaml"

  info "Applying RBAC..."
  kubectl apply -f "${SCRIPT_DIR}/deploy/controller/rbac.yaml"

  info "Creating TLS certificate (requires cert-manager)..."
  kubectl apply -f "${SCRIPT_DIR}/deploy/controller/certificate.yaml"

  info "Waiting for certificate to be ready..."
  if ! kubectl wait --for=condition=Ready \
    certificate/jafra-controller-serving-cert \
    -n jafra-system --timeout=120s 2>/dev/null; then
    error "Certificate not ready. Is cert-manager installed?"
    error "  Re-run with: $0 --install-cert-manager"
    error "  Or: kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml"
    exit 1
  fi

  info "Deploying service..."
  kubectl apply -f "${SCRIPT_DIR}/deploy/controller/service.yaml"

  info "Deploying controller..."
  kubectl apply -f "${SCRIPT_DIR}/deploy/controller/deployment.yaml"

  info "Waiting for controller rollout..."
  kubectl rollout status deployment/jafra-controller \
    -n jafra-system --timeout=120s

  info "Registering webhook..."
  kubectl apply -f "${SCRIPT_DIR}/deploy/controller/webhook.yaml"

  info "Controller ready"
}

deploy_analyzer() {
  step "Deploying jafra-analyzer"

  kubectl apply -f "${SCRIPT_DIR}/deploy/analyzer/deployment.yaml"

  info "Waiting for analyzer rollout..."
  kubectl rollout status deployment/jafra-analyzer \
    -n jafra-system --timeout=180s

  info "Analyzer ready"
}

deploy_agent() {
  step "Deploying jafra-agent"

  kubectl apply -f "${SCRIPT_DIR}/deploy/agent/rbac.yaml"
  kubectl apply -f "${SCRIPT_DIR}/deploy/agent/daemonset.yaml"

  info "Waiting for agent rollout..."
  kubectl rollout status daemonset/jafra-agent \
    -n jafra-system --timeout=120s

  info "Agent ready (mode: log-only)"
}

switch_agent_to_grpc() {
  step "Switching agent to gRPC mode"

  kubectl set env daemonset/jafra-agent \
    -n jafra-system JAFRA_MODE=grpc

  info "Waiting for agent restart..."
  sleep 3
  kubectl rollout status daemonset/jafra-agent \
    -n jafra-system --timeout=120s

  info "Agent now streaming to analyzer"
}

deploy_mcp() {
  step "Deploying async-profiler MCP server"

  if [[ ! -f "${MCP_MANIFEST}" ]]; then
    error "MCP Kind manifest missing: ${MCP_MANIFEST}"
    error "Clone Async-MCP into the repo root first:"
    error "  git clone https://github.com/khansaad/Async-MCP.git Async-MCP"
    exit 1
  fi

  # Analyzer must already be reachable in-cluster for JAFRA_ANALYZER_URL.
  if ! kubectl get svc jafra-analyzer -n jafra-system &>/dev/null; then
    error "jafra-analyzer Service not found in jafra-system."
    error "Deploy the Jafra stack first (or run without --deploy-only)."
    exit 1
  fi

  info "Manifest: ${MCP_MANIFEST}"
  info "Image:    ${MCP_IMAGE}"
  info "JAFRA_ANALYZER_URL=http://jafra-analyzer.jafra-system.svc.cluster.local:8080"

  # Kind yaml already sets analyzer DNS; pin the pulled/loaded image tag.
  kubectl apply -f "${MCP_MANIFEST}"
  kubectl set image deployment/async-profiler-mcp-server \
    -n jafra-system "mcp-server=${MCP_IMAGE}"

  info "Waiting for MCP server rollout..."
  kubectl rollout status deployment/async-profiler-mcp-server \
    -n jafra-system --timeout=180s

  info "MCP server ready"
}

deploy_all() {
  deploy_controller
  deploy_analyzer
  deploy_agent
  switch_agent_to_grpc

  if [[ "${WITH_MCP}" == "true" ]]; then
    deploy_mcp
  fi
}

verify() {
  step "Verifying Jafra installation"
  echo ""

  info "Namespace:"
  kubectl get namespace jafra-system 2>/dev/null || warn "jafra-system not found"
  echo ""

  info "Jafra components:"
  kubectl get pods -n jafra-system -o wide 2>/dev/null || true
  echo ""

  info "Webhook:"
  kubectl get mutatingwebhookconfiguration jafra-controller 2>/dev/null || warn "webhook not registered"
  echo ""

  if [[ "${WITH_MCP}" == "true" ]]; then
    info "MCP server:"
    kubectl get deploy,svc async-profiler-mcp-server -n jafra-system 2>/dev/null || warn "MCP not found"
    echo ""
    info "MCP connects to analyzer at:"
    info "  http://jafra-analyzer.jafra-system.svc.cluster.local:8080"
    info ""
    info "Port-forward MCP for local agents / MCP Inspector:"
    info "  kubectl -n jafra-system port-forward svc/async-profiler-mcp-server 18081:8080"
    info "  # Streamable HTTP: http://127.0.0.1:18081/mcp/"
    info "  # Optional smoke test (from Async-MCP clone):"
    info "  #   python3 Async-MCP/smoke_test.py http://127.0.0.1:18081"
    echo ""
  fi

  info "Jafra is ready. To profile a Java app, add these labels to your Pod:"
  info ""
  info "  labels:"
  info "    jafra.io/enabled: \"true\""
  info "    jafra.io/mode: \"continuous\""
  info "  annotations:"
  info "    jafra.io/containers: \"<your-container-name>\""
  info ""
  info "Then access the analyzer API:"
  info "  kubectl -n jafra-system port-forward svc/jafra-analyzer 8080:8080"
  info "  curl http://127.0.0.1:8080/api/v1/recordings"
}

usage() {
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
  echo "  $0 --deploy-only --mcp"
  echo "  $0 --install-cert-manager --mcp"
  echo "  $0 --teardown"
  echo "  $0 --teardown --uninstall-cert-manager"
  echo ""
  echo "This script pulls published images. To build from source instead, use ./install-jafra.sh"
  echo ""
  echo "Environment:"
  echo "  KIND_CLUSTER    Kind cluster name (default: jafra)"
  echo "  JAFRA_VERSION   Jafra image tag (default: 0.1.0)"
  echo "  MCP_VERSION     MCP image tag (default: 0.1.0)"
  echo "  MCP_IMAGE        Full MCP image override"
  echo ""
  echo "Notes:"
  echo "  --install-cert-manager labels namespace/cert-manager so a later"
  echo "  --teardown will uninstall cert-manager automatically."
  echo "  Pre-existing cert-manager is left alone unless you pass"
  echo "  --teardown --uninstall-cert-manager."
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
  check_prerequisites

  if [[ "${TEARDOWN}" == "true" ]]; then
    teardown
    exit 0
  fi

  if [[ "${INSTALL_CERT_MANAGER}" == "true" ]]; then
    install_cert_manager
  fi

  if [[ "${DEPLOY_ONLY}" != "true" ]]; then
    ensure_images "${FORCE_PULL}"
    load_images
  fi

  deploy_all
  verify
}

main "$@"
