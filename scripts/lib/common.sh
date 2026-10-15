# shellcheck shell=bash
# Shared helpers for install-jafra.sh

: "${SCRIPT_DIR:?SCRIPT_DIR must be set before sourcing common.sh}"

JAFRA_TARGET="${JAFRA_TARGET:-kind}"
JAFRA_NAMESPACE="${JAFRA_NAMESPACE:-jafra-system}"
KIND_CLUSTER="${KIND_CLUSTER:-jafra}"
JAFRA_VERSION="${JAFRA_VERSION:-0.0.2}"
JAFRA_REGISTRY="${JAFRA_REGISTRY:-quay.io/bharathappali}"
# Legacy alias used in install-jafra usage text.
VERSION="${JAFRA_VERSION}"

CONTROLLER_TAG="${JAFRA_CONTROLLER_VERSION:-${JAFRA_VERSION}}"
AGENT_TAG="${JAFRA_AGENT_VERSION:-${JAFRA_VERSION}}"
ANALYZER_TAG="${JAFRA_ANALYZER_VERSION:-${JAFRA_VERSION}}"

CONTROLLER_IMAGE="${JAFRA_REGISTRY}/jafra-controller:${CONTROLLER_TAG}"
AGENT_IMAGE="${JAFRA_REGISTRY}/jafra-agent:${AGENT_TAG}"
ANALYZER_IMAGE="${JAFRA_REGISTRY}/jafra-analyzer:${ANALYZER_TAG}"

KUSTOMIZE_WEBHOOK="${SCRIPT_DIR}/deploy/controller/webhook.yaml"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[jafra]${NC} $*"; }
warn()  { echo -e "${YELLOW}[jafra]${NC} $*"; }
error() { echo -e "${RED}[jafra]${NC} $*" >&2; }
step()  { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

kubectl_cmd() {
  kubectl "$@"
}

oc_cmd() {
  if command -v oc >/dev/null 2>&1; then
    oc "$@"
  else
    kubectl "$@"
  fi
}

require_namespace_matches_manifests() {
  if [[ "${JAFRA_NAMESPACE}" != "jafra-system" ]]; then
    error "Custom JAFRA_NAMESPACE=${JAFRA_NAMESPACE} is not supported yet."
    error "Manifests under deploy/ are pinned to namespace jafra-system."
    exit 1
  fi
}

image_exists() {
  docker image inspect "$1" &>/dev/null
}

validate_target() {
  case "${JAFRA_TARGET}" in
    kind|openshift) ;;
    *)
      error "Invalid target '${JAFRA_TARGET}'. Use kind or openshift."
      exit 1
      ;;
  esac
}
