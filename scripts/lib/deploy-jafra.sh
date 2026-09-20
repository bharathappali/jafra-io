# shellcheck shell=bash

ensure_platform_namespace() {
  if kubectl_cmd get namespace "${JAFRA_NAMESPACE}" &>/dev/null; then
    info "Namespace ${JAFRA_NAMESPACE} already exists"
  else
    info "Creating namespace ${JAFRA_NAMESPACE}..."
  fi
  kubectl_cmd apply -f "${SCRIPT_DIR}/deploy/controller/namespace.yaml"
}

deploy_controller() {
  step "Deploying jafra-controller"

  require_cert_manager

  ensure_platform_namespace

  info "Applying RBAC..."
  kubectl_cmd apply -f "${SCRIPT_DIR}/deploy/controller/rbac.yaml"

  info "Creating TLS certificate (requires cert-manager)..."
  kubectl_cmd apply -f "${SCRIPT_DIR}/deploy/controller/certificate.yaml"

  info "Waiting for certificate to be ready..."
  if ! kubectl_cmd wait --for=condition=Ready \
    certificate/jafra-controller-serving-cert \
    -n "${JAFRA_NAMESPACE}" --timeout=120s 2>/dev/null; then
    error "Certificate not ready. Is cert-manager installed?"
    error "  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml"
    exit 1
  fi

  info "Deploying service..."
  kubectl_cmd apply -f "${SCRIPT_DIR}/deploy/controller/service.yaml"

  info "Deploying controller..."
  kubectl_cmd apply -f "${SCRIPT_DIR}/deploy/controller/deployment.yaml"

  info "Waiting for controller rollout..."
  kubectl_cmd rollout status deployment/jafra-controller \
    -n "${JAFRA_NAMESPACE}" --timeout=120s

  if [[ "${JAFRA_TARGET}" == "openshift" ]]; then
    require_webhook_permission
  fi

  info "Registering webhook..."
  kubectl_cmd apply -f "${SCRIPT_DIR}/deploy/controller/webhook.yaml"

  info "Controller ready"
}

deploy_analyzer() {
  step "Deploying jafra-analyzer"

  kubectl_cmd apply -f "${SCRIPT_DIR}/deploy/analyzer/deployment.yaml"

  info "Waiting for analyzer rollout..."
  kubectl_cmd rollout status deployment/jafra-analyzer \
    -n "${JAFRA_NAMESPACE}" --timeout=180s

  info "Analyzer ready"
}

deploy_agent() {
  step "Deploying jafra-agent"

  kubectl_cmd apply -f "${SCRIPT_DIR}/deploy/agent/rbac.yaml"
  kubectl_cmd apply -f "${SCRIPT_DIR}/deploy/agent/daemonset.yaml"

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
  deploy_controller
  deploy_analyzer
  deploy_agent
  switch_agent_to_grpc
}

teardown_jafra() {
  step "Tearing down Jafra ecosystem"

  warn "Deleting webhook..."
  kubectl_cmd delete -f "${SCRIPT_DIR}/deploy/controller/webhook.yaml" --ignore-not-found 2>/dev/null || true

  warn "Deleting agent..."
  kubectl_cmd delete -f "${SCRIPT_DIR}/deploy/agent/daemonset.yaml" --ignore-not-found 2>/dev/null || true
  kubectl_cmd delete -f "${SCRIPT_DIR}/deploy/agent/rbac.yaml" --ignore-not-found 2>/dev/null || true

  warn "Deleting analyzer..."
  kubectl_cmd delete -f "${SCRIPT_DIR}/deploy/analyzer/deployment.yaml" --ignore-not-found 2>/dev/null || true

  warn "Deleting controller..."
  kubectl_cmd delete -f "${SCRIPT_DIR}/deploy/controller/deployment.yaml" --ignore-not-found 2>/dev/null || true
  kubectl_cmd delete -f "${SCRIPT_DIR}/deploy/controller/service.yaml" --ignore-not-found 2>/dev/null || true
  kubectl_cmd delete -f "${SCRIPT_DIR}/deploy/controller/certificate.yaml" --ignore-not-found 2>/dev/null || true
  kubectl_cmd delete -f "${SCRIPT_DIR}/deploy/controller/rbac.yaml" --ignore-not-found 2>/dev/null || true

  if [[ "${JAFRA_TARGET}" == "openshift" ]]; then
    warn "Deleting custom jafra-agent SCC binding..."
    kubectl_cmd delete -f "${SCRIPT_DIR}/deploy/openshift/scc-platform.yaml" --ignore-not-found 2>/dev/null || true
    kubectl_cmd delete rolebinding jafra-agent-node-exporter -n "${JAFRA_NAMESPACE}" --ignore-not-found 2>/dev/null || true
    kubectl_cmd delete rolebinding jafra-agent-hostmount -n "${JAFRA_NAMESPACE}" --ignore-not-found 2>/dev/null || true
    if kubectl_cmd auth can-i delete securitycontextconstraints.security.openshift.io/jafra-agent --all-namespaces &>/dev/null; then
      kubectl_cmd delete -f "${SCRIPT_DIR}/deploy/openshift/scc-jafra-agent.yaml" --ignore-not-found 2>/dev/null || true
    fi
  fi

  warn "Deleting namespace..."
  kubectl_cmd delete namespace "${JAFRA_NAMESPACE}" --ignore-not-found 2>/dev/null || true

  info "Teardown complete"
}

verify_jafra() {
  step "Verifying Jafra installation"
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
