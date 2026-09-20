# shellcheck shell=bash

openshift_detected() {
  kubectl_cmd get ns openshift-operator-lifecycle-manager &>/dev/null ||
    kubectl_cmd api-resources --api-group=security.openshift.io 2>/dev/null | grep -q securitycontextconstraints
}

check_openshift_prerequisites() {
  local missing=0
  for cmd in kubectl; do
    if ! command -v "$cmd" &>/dev/null; then
      error "$cmd is required but not found"
      missing=1
    fi
  done
  if [[ $missing -ne 0 ]]; then
    exit 1
  fi

  if ! openshift_detected; then
    error "OpenShift APIs not detected in the current cluster context."
    error "Log in with 'oc login' or point kubectl at an OpenShift cluster."
    error "Use --target kind for local Kind installs."
    exit 1
  fi

  info "OpenShift cluster detected"
  if command -v oc >/dev/null 2>&1; then
    oc_cmd whoami &>/dev/null && info "Logged in as: $(oc_cmd whoami)" || warn "oc whoami failed; continuing with kubectl context"
  fi
}

can_bind_scc_clusterrole() {
  local role="$1"
  kubectl_cmd auth can-i bind "clusterrole/${role}" --all-namespaces &>/dev/null ||
    kubectl_cmd auth can-i create rolebindings --namespace="${JAFRA_NAMESPACE}" &>/dev/null
}

apply_jafra_agent_scc() {
  step "Ensuring jafra-agent SCC exists"

  if ! kubectl_cmd get scc jafra-agent &>/dev/null; then
    if ! kubectl_cmd auth can-i create securitycontextconstraints.security.openshift.io --all-namespaces &>/dev/null; then
      error "Custom SCC jafra-agent is missing and cannot be created (need cluster-admin)."
      error "Ask a cluster admin to apply:"
      error "  kubectl apply -f ${SCRIPT_DIR}/deploy/openshift/scc-jafra-agent.yaml"
      exit 1
    fi
    kubectl_cmd apply -f "${SCRIPT_DIR}/deploy/openshift/scc-jafra-agent.yaml"
    info "Created SCC jafra-agent and ClusterRole system:openshift:scc:jafra-agent"
  elif ! kubectl_cmd get clusterrole system:openshift:scc:jafra-agent &>/dev/null; then
    warn "SCC jafra-agent exists but ClusterRole is missing; applying ClusterRole"
    kubectl_cmd apply -f "${SCRIPT_DIR}/deploy/openshift/scc-jafra-agent.yaml"
  else
    info "SCC jafra-agent already exists"
  fi
}

apply_platform_scc_bindings() {
  step "Applying platform SCC bindings (${JAFRA_NAMESPACE})"

  ensure_platform_namespace
  apply_jafra_agent_scc

  if ! can_bind_scc_clusterrole "system:openshift:scc:jafra-agent"; then
    error "Cannot bind OpenShift SCC ClusterRoles in namespace ${JAFRA_NAMESPACE}."
    error "Ask a cluster admin to apply after the namespace exists:"
    error "  kubectl apply -f ${SCRIPT_DIR}/deploy/controller/namespace.yaml"
    error "  kubectl apply -f ${SCRIPT_DIR}/deploy/openshift/scc-platform.yaml"
    error "Or run: $0 --target openshift --deploy-only"
    exit 1
  fi

  kubectl_cmd apply -f "${SCRIPT_DIR}/deploy/openshift/scc-platform.yaml"
  info "Platform SCC bindings applied"
}

openshift_pre_deploy() {
  apply_platform_scc_bindings

  if ! cert_manager_installed; then
    warn "cert-manager is not installed. Webhook TLS requires cert-manager or manual certs."
    warn "Install with: $0 --target openshift --install-cert-manager"
    warn "Or ask a cluster admin to install cert-manager cluster-wide."
  fi
}

openshift_post_deploy() {
  verify_openshift
}

verify_openshift() {
  info "OpenShift SCC bindings (platform):"
  kubectl_cmd get rolebinding -n "${JAFRA_NAMESPACE}" \
    -l app.kubernetes.io/part-of=jafra 2>/dev/null || true
  echo ""
  info "Java workloads use emptyDir recordings; no per-namespace workload SCC is required."
  info "See deploy/openshift/README.md for the minimal permission model."
}
