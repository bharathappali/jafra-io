# shellcheck shell=bash
# Writes deploy/kustomize/components/versions/kustomization.yaml from env (gitignored).

: "${SCRIPT_DIR:?SCRIPT_DIR must be set before sourcing kustomize-versions.sh}"

KUSTOMIZE_VERSIONS_DIR="${SCRIPT_DIR}/deploy/kustomize/components/versions"
KUSTOMIZE_VERSIONS_FILE="${KUSTOMIZE_VERSIONS_DIR}/kustomization.yaml"

# Image references in base manifests (name field for kustomize images transformer).
JAFRA_IMAGE_CONTROLLER="quay.io/bharathappali/jafra-controller"
JAFRA_IMAGE_AGENT="quay.io/bharathappali/jafra-agent"
JAFRA_IMAGE_ANALYZER="quay.io/bharathappali/jafra-analyzer"

resolve_component_versions() {
  local default="${JAFRA_VERSION:-0.0.2}"
  CONTROLLER_TAG="${JAFRA_CONTROLLER_VERSION:-${default}}"
  AGENT_TAG="${JAFRA_AGENT_VERSION:-${default}}"
  ANALYZER_TAG="${JAFRA_ANALYZER_VERSION:-${default}}"
  REGISTRY="${JAFRA_REGISTRY:-quay.io/bharathappali}"

  CONTROLLER_IMAGE="${REGISTRY}/jafra-controller:${CONTROLLER_TAG}"
  AGENT_IMAGE="${REGISTRY}/jafra-agent:${AGENT_TAG}"
  ANALYZER_IMAGE="${REGISTRY}/jafra-analyzer:${ANALYZER_TAG}"
}

write_versions_component() {
  resolve_component_versions
  mkdir -p "${KUSTOMIZE_VERSIONS_DIR}"
  cat >"${KUSTOMIZE_VERSIONS_FILE}" <<EOF
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
images:
  - name: ${JAFRA_IMAGE_CONTROLLER}
    newName: ${REGISTRY}/jafra-controller
    newTag: "${CONTROLLER_TAG}"
  - name: ${JAFRA_IMAGE_AGENT}
    newName: ${REGISTRY}/jafra-agent
    newTag: "${AGENT_TAG}"
  - name: ${JAFRA_IMAGE_ANALYZER}
    newName: ${REGISTRY}/jafra-analyzer
    newTag: "${ANALYZER_TAG}"
EOF
  info "Kustomize images: controller=${CONTROLLER_TAG} agent=${AGENT_TAG} analyzer=${ANALYZER_TAG} registry=${REGISTRY}"
}

kustomize_apply_phase() {
  local phase="$1"
  local dir="${SCRIPT_DIR}/deploy/kustomize/phases/${phase}"
  if [[ ! -f "${dir}/kustomization.yaml" ]]; then
    error "Missing kustomize phase: ${dir}"
    exit 1
  fi
  kubectl_cmd apply -k "${dir}"
}

kustomize_delete_phase() {
  local phase="$1"
  local dir="${SCRIPT_DIR}/deploy/kustomize/phases/${phase}"
  if [[ ! -f "${dir}/kustomization.yaml" ]]; then
    return 0
  fi
  kubectl_cmd delete -k "${dir}" --ignore-not-found 2>/dev/null || true
}
