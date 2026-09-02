# shellcheck shell=bash
# Shared helpers for install-jafra.sh

: "${SCRIPT_DIR:?SCRIPT_DIR must be set before sourcing common.sh}"

JAFRA_TARGET="${JAFRA_TARGET:-kind}"
JAFRA_NAMESPACE="${JAFRA_NAMESPACE:-jafra-system}"
KIND_CLUSTER="${KIND_CLUSTER:-jafra}"
VERSION="${JAFRA_VERSION:-0.0.2}"
JAFRA_REGISTRY="${JAFRA_REGISTRY:-quay.io/bharathappali}"

CONTROLLER_IMAGE="${JAFRA_REGISTRY}/jafra-controller:${VERSION}"
AGENT_IMAGE="${JAFRA_REGISTRY}/jafra-agent:${VERSION}"
ANALYZER_IMAGE="${JAFRA_REGISTRY}/jafra-analyzer:${VERSION}"

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
