# shellcheck shell=bash

cert_manager_crds_ready() {
  kubectl_cmd get crd certificates.cert-manager.io &>/dev/null &&
    kubectl_cmd get crd issuers.cert-manager.io &>/dev/null
}

cert_manager_installed() {
  cert_manager_crds_ready &&
    kubectl_cmd get namespace cert-manager &>/dev/null &&
    kubectl_cmd get deployment cert-manager -n cert-manager &>/dev/null &&
    kubectl_cmd get deployment cert-manager-webhook -n cert-manager &>/dev/null &&
    kubectl_cmd get deployment cert-manager-cainjector -n cert-manager &>/dev/null
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

install_cert_manager() {
  step "Installing cert-manager"

  if cert_manager_installed; then
    info "cert-manager is already installed, skipping"
    return
  fi

  if [[ "${JAFRA_TARGET}" == "openshift" ]]; then
    warn "Installing cert-manager on OpenShift requires cluster-admin permissions."
  fi

  info "Applying cert-manager manifests..."
  kubectl_cmd apply -f "https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml"

  info "Waiting for cert-manager CRDs..."
  kubectl_cmd wait --for=condition=Established crd/certificates.cert-manager.io --timeout=120s
  kubectl_cmd wait --for=condition=Established crd/issuers.cert-manager.io --timeout=120s

  info "Waiting for cert-manager deployments..."
  kubectl_cmd rollout status deployment/cert-manager -n cert-manager --timeout=180s
  kubectl_cmd rollout status deployment/cert-manager-webhook -n cert-manager --timeout=180s
  kubectl_cmd rollout status deployment/cert-manager-cainjector -n cert-manager --timeout=180s

  info "cert-manager is ready"
}

can_create_mutating_webhook() {
  kubectl_cmd auth can-i create mutatingwebhookconfigurations \
    --all-namespaces &>/dev/null
}

require_webhook_permission() {
  if can_create_mutating_webhook; then
    return 0
  fi

  error "Current user cannot create MutatingWebhookConfiguration (cluster-scoped)."
  error "Ask a cluster admin to apply deploy/controller/webhook.yaml, then re-run:"
  error "  $0 --target ${JAFRA_TARGET} --deploy-only"
  exit 1
}
