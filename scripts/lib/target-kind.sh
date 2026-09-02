# shellcheck shell=bash

check_kind_prerequisites() {
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

  kubectl_cmd config use-context "kind-${KIND_CLUSTER}" &>/dev/null || true
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

ensure_kind_images() {
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

load_kind_images() {
  step "Loading images into Kind cluster '${KIND_CLUSTER}'"

  kind load docker-image "${CONTROLLER_IMAGE}" --name "${KIND_CLUSTER}"
  kind load docker-image "${AGENT_IMAGE}" --name "${KIND_CLUSTER}"
  kind load docker-image "${ANALYZER_IMAGE}" --name "${KIND_CLUSTER}"

  info "All images loaded"
}

kind_pre_deploy() {
  : # Kind has no platform-specific pre-deploy steps.
}

kind_post_deploy() {
  : # Kind uses the shared verify_jafra output.
}
