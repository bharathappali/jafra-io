#!/usr/bin/env bash
# install-jafra.sh — Load images and deploy the Jafra ecosystem into a Kind cluster.
#
# Usage:
#   ./install-jafra.sh                  # load images + deploy (build only if image missing)
#   ./install-jafra.sh --force-build           # rebuild all images, then load + deploy
#   ./install-jafra.sh --deploy-only           # skip image check/load, just apply manifests
#   ./install-jafra.sh --install-cert-manager  # install cert-manager first, then deploy
#   ./install-jafra.sh --teardown              # delete everything Jafra-related
#
# Prerequisites:
#   - kind cluster named "jafra" (or set KIND_CLUSTER)
#   - docker, kubectl, kind
#   - cert-manager already installed in the cluster

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIND_CLUSTER="${KIND_CLUSTER:-jafra}"
VERSION="${JAFRA_VERSION:-0.1.0}"

CONTROLLER_IMAGE="quay.io/bharathappali/jafra-controller:${VERSION}"
AGENT_IMAGE="quay.io/bharathappali/jafra-agent:${VERSION}"
ANALYZER_IMAGE="quay.io/bharathappali/jafra-analyzer:${VERSION}"

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

  info "Teardown complete"
}

install_cert_manager() {
  step "Installing cert-manager"

  if cert_manager_installed; then
    info "cert-manager is already installed, skipping"
    return
  fi

  info "Applying cert-manager manifests..."
  kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml"

  info "Waiting for cert-manager CRDs..."
  kubectl wait --for=condition=Established crd/certificates.cert-manager.io --timeout=120s
  kubectl wait --for=condition=Established crd/issuers.cert-manager.io --timeout=120s

  info "Waiting for cert-manager deployments..."
  kubectl rollout status deployment/cert-manager -n cert-manager --timeout=180s
  kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=180s
  kubectl rollout status deployment/cert-manager-cainjector -n cert-manager --timeout=180s

  info "cert-manager is ready"
}

build_image_if_needed() {
  local image="$1"
  local dockerfile="$2"
  local context="$3"
  local force="$4"

  if [[ "$force" == "true" ]] || ! image_exists "$image"; then
    if [[ "$force" == "true" ]]; then
      info "Force building ${image}..."
    else
      warn "${image} not found locally, building..."
    fi
    docker build -f "$dockerfile" -t "$image" "$context"
  else
    info "${image} already exists locally, skipping build"
  fi
}

ensure_images() {
  local force="${1:-false}"

  step "Checking container images (force-build=${force})"

  build_image_if_needed \
    "${CONTROLLER_IMAGE}" \
    "${SCRIPT_DIR}/jafra-controller/Dockerfile" \
    "${SCRIPT_DIR}/jafra-controller" \
    "$force"

  build_image_if_needed \
    "${AGENT_IMAGE}" \
    "${SCRIPT_DIR}/jafra-agent/Dockerfile" \
    "${SCRIPT_DIR}" \
    "$force"

  build_image_if_needed \
    "${ANALYZER_IMAGE}" \
    "${SCRIPT_DIR}/jafra-analyzer/Dockerfile" \
    "${SCRIPT_DIR}" \
    "$force"
}

load_images() {
  step "Loading images into Kind cluster '${KIND_CLUSTER}'"

  kind load docker-image "${CONTROLLER_IMAGE}" --name "${KIND_CLUSTER}"
  kind load docker-image "${AGENT_IMAGE}" --name "${KIND_CLUSTER}"
  kind load docker-image "${ANALYZER_IMAGE}" --name "${KIND_CLUSTER}"

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
    error "  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml"
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

deploy_all() {
  deploy_controller
  deploy_analyzer
  deploy_agent
  switch_agent_to_grpc
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

main() {
  case "${1:-}" in
    --teardown)
      check_prerequisites
      teardown
      exit 0
      ;;
    --install-cert-manager)
      check_prerequisites
      install_cert_manager
      ensure_images false
      load_images
      deploy_all
      verify
      ;;
    --deploy-only)
      check_prerequisites
      deploy_all
      verify
      ;;
    --force-build)
      check_prerequisites
      ensure_images true
      load_images
      deploy_all
      verify
      ;;
    --help|-h)
      echo "Usage: $0 [--force-build | --deploy-only | --install-cert-manager | --teardown | --help]"
      echo ""
      echo "  (no args)       Check images, build only if missing, load into Kind, deploy"
      echo "  --force-build   Rebuild all images even if they exist, then load + deploy"
      echo "  --install-cert-manager  Install cert-manager first, then continue install"
      echo "  --deploy-only   Skip image check/load, just apply Kubernetes manifests"
      echo "  --teardown      Remove all Jafra resources from the cluster"
      echo ""
      echo "Environment:"
      echo "  KIND_CLUSTER    Kind cluster name (default: jafra)"
      echo "  JAFRA_VERSION   Image tag (default: 0.1.0)"
      exit 0
      ;;
    "")
      check_prerequisites
      ensure_images false
      load_images
      deploy_all
      verify
      ;;
    *)
      error "Unknown option: $1"
      echo "Run '$0 --help' for usage"
      exit 1
      ;;
  esac
}

main "$@"
