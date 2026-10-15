# shellcheck shell=bash

# shellcheck source=scripts/lib/kustomize-versions.sh
source "${SCRIPT_DIR}/scripts/lib/kustomize-versions.sh"

ensure_platform_namespace() {
  write_versions_component
  if kubectl_cmd get namespace "${JAFRA_NAMESPACE}" &>/dev/null; then
    info "Namespace ${JAFRA_NAMESPACE} already exists"
  else
    info "Creating namespace ${JAFRA_NAMESPACE}..."
  fi
  kustomize_apply_phase bootstrap
}

deploy_controller() {
  step "Deploying jafra-controller"

  require_cert_manager

  ensure_platform_namespace

  info "Waiting for certificate to be ready..."
  if ! kubectl_cmd wait --for=condition=Ready \
    certificate/jafra-controller-serving-cert \
    -n "${JAFRA_NAMESPACE}" --timeout=120s 2>/dev/null; then
    error "Certificate not ready. Is cert-manager installed?"
    error "  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml"
    exit 1
  fi

  info "Deploying controller service and deployment..."
  kustomize_apply_phase controller

  info "Waiting for controller rollout..."
  kubectl_cmd rollout status deployment/jafra-controller \
    -n "${JAFRA_NAMESPACE}" --timeout=120s

  if [[ "${JAFRA_TARGET}" == "openshift" ]]; then
    require_webhook_permission
  fi

  info "Registering webhook..."
  kubectl_cmd apply -f "${KUSTOMIZE_WEBHOOK}"

  info "Controller ready"
}

deploy_analyzer() {
  step "Deploying jafra-analyzer"

  kustomize_apply_phase analyzer

  info "Waiting for analyzer rollout..."
  kubectl_cmd rollout status deployment/jafra-analyzer \
    -n "${JAFRA_NAMESPACE}" --timeout=180s

  info "Analyzer ready"
}

deploy_agent() {
  step "Deploying jafra-agent"

  kustomize_apply_phase agent

  info "Waiting for agent rollout..."
  kubectl_cmd rollout status daemonset/jafra-agent \
    -n "${JAFRA_NAMESPACE}" --timeout=120s

  info "Agent ready (mode: log-only)"
}

switch_agent_to_grpc() {
  step "Switching agent to gRPC mode"

  kubectl_cmd set env daemonset/jafra-agent \
    -n "${JAFRA_NAMESPACE}" JAFRA_MODE=grpc

  info "Waiting for agent restart..."
  sleep 3
  kubectl_cmd rollout status daemonset/jafra-agent \
    -n "${JAFRA_NAMESPACE}" --timeout=120s

  info "Agent now streaming to analyzer"
}

deploy_all() {
  write_versions_component
  deploy_controller
  deploy_analyzer
  deploy_agent
  switch_agent_to_grpc
}

teardown_jafra() {
  step "Tearing down Jafra ecosystem"

  write_versions_component

  warn "Deleting webhook..."
  kubectl_cmd delete -f "${KUSTOMIZE_WEBHOOK}" --ignore-not-found 2>/dev/null || true

  warn "Deleting agent..."
  kustomize_delete_phase agent

  warn "Deleting analyzer..."
  kustomize_delete_phase analyzer

  warn "Deleting controller..."
  kustomize_delete_phase controller

  warn "Deleting platform bootstrap (RBAC, certificate, namespace)..."
  kustomize_delete_phase bootstrap

  if [[ "${JAFRA_TARGET}" == "openshift" ]]; then
    warn "Deleting custom jafra-agent SCC binding..."
    kubectl_cmd delete -f "${SCRIPT_DIR}/deploy/openshift/scc-platform.yaml" --ignore-not-found 2>/dev/null || true
    kubectl_cmd delete rolebinding jafra-agent-node-exporter -n "${JAFRA_NAMESPACE}" --ignore-not-found 2>/dev/null || true
    kubectl_cmd delete rolebinding jafra-agent-hostmount -n "${JAFRA_NAMESPACE}" --ignore-not-found 2>/dev/null || true
    if kubectl_cmd auth can-i delete securitycontextconstraints.security.openshift.io/jafra-agent --all-namespaces &>/dev/null; then
      kubectl_cmd delete -f "${SCRIPT_DIR}/deploy/openshift/scc-jafra-agent.yaml" --ignore-not-found 2>/dev/null || true
    fi
  fi

  warn "Deleting namespace if still present..."
  kubectl_cmd delete namespace "${JAFRA_NAMESPACE}" --ignore-not-found 2>/dev/null || true

  info "Teardown complete"
}

verify_jafra() {
  step "Verifying Jafra installation"
  echo ""

  resolve_component_versions
  info "Images: controller=${CONTROLLER_IMAGE} agent=${AGENT_IMAGE} analyzer=${ANALYZER_IMAGE}"
  echo ""

  info "Namespace:"
  kubectl_cmd get namespace "${JAFRA_NAMESPACE}" 2>/dev/null || warn "${JAFRA_NAMESPACE} not found"
  echo ""

  info "Jafra components:"
  kubectl_cmd get pods -n "${JAFRA_NAMESPACE}" -o wide 2>/dev/null || true
  echo ""

  info "Webhook:"
  kubectl_cmd get mutatingwebhookconfiguration jafra-controller 2>/dev/null || warn "webhook not registered"
  echo ""

  if [[ "${JAFRA_TARGET}" == "openshift" ]]; then
    verify_openshift
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
  info "  kubectl -n ${JAFRA_NAMESPACE} port-forward svc/jafra-analyzer 8080:8080"
  info "  curl http://127.0.0.1:8080/api/v1/recordings"
}
