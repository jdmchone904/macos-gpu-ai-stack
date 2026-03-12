#!/opt/homebrew/bin/bash
# =============================================================================
# lib/backend.sh — Backend management (gpustack backend)
# =============================================================================

backend_help() {
  echo ""
  echo -e "${BOLD}Usage:${RESET} gpustack backend <subcommand> [backend]"
  echo ""
  echo -e "${BOLD}Subcommands:${RESET}"
  echo -e "  ${CYAN}start${RESET}              Start the active backend deployment"
  echo -e "  ${CYAN}stop${RESET}               Stop the active backend deployment"
  echo -e "  ${CYAN}status${RESET}             Show health, pod status, and recent logs"
  echo -e "  ${CYAN}logs${RESET}               Tail logs for the active backend pod"
  echo -e "  ${CYAN}switch <backend>${RESET}   Switch active backend (llamacpp | ollama)"
  echo ""
  echo -e "${BOLD}Options:${RESET}"
  echo -e "  ${CYAN}-h, --help${RESET}   Show this help message"
  echo ""
  echo -e "${BOLD}Examples:${RESET}"
  echo -e "  ./gpustack backend status"
  echo -e "  ./gpustack backend switch ollama"
  echo -e "  ./gpustack backend logs"
  echo ""
}

# --- Wait for deployment to be fully healthy ---------------------------------

# _wait_for_backend_deployment BACKEND
# 1. Waits for deployment object to exist
# 2. Waits for rollout to complete
# 3. Waits for pod to reach Running
# 4. Polls /health until the backend is actually serving
_wait_for_backend_deployment() {
  local backend="$1"
  local ns="$backend"
  local timeout=300 elapsed=0

  step "Waiting for $backend deployment to be fully ready"

  # 1. Deployment object
  info "Waiting for $backend deployment object..."
  elapsed=0
  until kubectl get deployment "$backend" -n "$ns" &>/dev/null 2>&1; do
    (( elapsed >= timeout )) && error "Timed out waiting for $backend deployment to appear"
    sleep 5; (( elapsed += 5 ))
    info "  Still waiting for deployment object... (${elapsed}s / ${timeout}s)"
  done
  success "$backend deployment object found"

  # 2. Rollout
  info "Waiting for $backend rollout to complete..."
  kubectl rollout status deployment/"$backend" -n "$ns" --timeout="${timeout}s" || \
    error "$backend rollout failed — check: kubectl describe deployment/$backend -n $ns"
  success "$backend rollout complete"

  # 3. Pod Running
  info "Waiting for $backend pod to reach Running state..."
  elapsed=0
  until kubectl get pods -n "$ns" --no-headers 2>/dev/null \
      | grep -E "^$backend-" | awk '{print $3}' | grep -q "^Running$"; do
    (( elapsed >= timeout )) && error "Timed out waiting for $backend pod to reach Running"
    sleep 5; (( elapsed += 5 ))
    local pod_status
    pod_status=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null \
      | grep -E "^$backend-" | awk '{print $1, $3, $4}' || echo "  (no pods yet)")
    info "  Pod status: $pod_status (${elapsed}s / ${timeout}s)"
  done
  success "$backend pod is Running"

  # 4. /health endpoint — may still be loading weights / discovering GPU devices
  local svc_port health_path
  svc_port=$(backend_port "$backend")
  if [[ -z "$svc_port" ]]; then
    warn "Unknown backend '$backend' — skipping health check"
    return 0
  fi

  case "$backend" in
    llamacpp) health_path="/health" ;;
    ollama)   health_path="/" ;;
    *)        health_path="/health" ;;
  esac

  info "Waiting for $backend health check on http://localhost:${svc_port}${health_path} ..."
  info "  (backend may still be loading weights or discovering GPU devices)"
  elapsed=0
  until curl -sf --max-time 5 "http://localhost:${svc_port}${health_path}" &>/dev/null; do
    if (( elapsed >= timeout )); then
      warn "Timed out waiting for $backend health after ${timeout}s — may still be initializing"
      warn "  Check manually: curl http://localhost:${svc_port}${health_path}"
      return 0
    fi
    sleep 5; (( elapsed += 5 ))
    info "  Still waiting... (${elapsed}s / ${timeout}s)"
  done
  success "$backend health OK — http://localhost:${svc_port}${health_path}"
}

# --- start -------------------------------------------------------------------
_backend_start() {
  local backend
  backend=$(active_backend)
  [[ -z "$backend" ]] && error "No backend is currently deployed. Run: ./gpustack setup"

  step "Starting $backend"
  local ns="$backend"

  local replicas
  replicas=$(kubectl get deployment "$backend" -n "$ns" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")

  if [[ "$replicas" -gt 0 ]]; then
    warn "$backend is already running (replicas=$replicas)"
  else
    info "Scaling $backend deployment to 1 replica..."
    kubectl scale deployment "$backend" -n "$ns" --replicas=1
  fi

  _wait_for_backend_deployment "$backend"
}

# --- stop --------------------------------------------------------------------
_backend_stop() {
  local backend
  backend=$(active_backend)
  [[ -z "$backend" ]] && error "No backend is currently deployed"

  step "Stopping $backend"
  info "Scaling $backend deployment to 0 replicas..."
  kubectl scale deployment "$backend" -n "$backend" --replicas=0
  success "$backend scaled down"
}

# --- status ------------------------------------------------------------------
_backend_status() {
  step "Backend status"

  local found=0
  for backend in llamacpp ollama; do
    if helm status "$backend" -n "$backend" &>/dev/null 2>&1; then
      found=1
      local port
      port=$(backend_port "$backend")

      echo -e "\n  ${BOLD}$backend${RESET}"

      # Pods
      echo -e "  ${CYAN}Pods:${RESET}"
      kubectl get pods -n "$backend" -o wide 2>/dev/null \
        | sed 's/^/    /' || echo "    (none)"

      # Health
      echo -e "  ${CYAN}Health:${RESET}"
      if curl -sf --max-time 5 "http://localhost:${port}/health" &>/dev/null; then
        echo -e "    ${GREEN}✓${RESET}  http://localhost:${port}/health  OK"
      else
        echo -e "    ${YELLOW}~${RESET}  http://localhost:${port}/health  not responding"
      fi

      # Recent logs (last 20 lines)
      echo -e "  ${CYAN}Recent logs (last 20 lines):${RESET}"
      local pod
      pod=$(kubectl get pods -n "$backend" --no-headers 2>/dev/null \
        | grep -E "^$backend-" | awk '{print $1}' | head -1 || true)
      if [[ -n "$pod" ]]; then
        kubectl logs "$pod" -n "$backend" --tail=20 2>/dev/null \
          | sed 's/^/    /' || echo "    (no logs)"
      else
        echo "    (no running pod)"
      fi
    fi
  done

  [[ $found -eq 0 ]] && warn "No backends are currently deployed. Run: ./gpustack setup"
  echo ""
}

# --- logs --------------------------------------------------------------------
_backend_logs() {
  local backend
  backend=$(active_backend)
  [[ -z "$backend" ]] && error "No backend is currently deployed"

  local pod
  pod=$(kubectl get pods -n "$backend" --no-headers 2>/dev/null \
    | grep -E "^$backend-" | awk '{print $1}' | head -1 || true)
  [[ -z "$pod" ]] && error "No running pod found for $backend"

  info "Tailing logs for $pod in namespace $backend (Ctrl+C to stop)..."
  kubectl logs -f "$pod" -n "$backend"
}

# --- switch ------------------------------------------------------------------
_backend_switch() {
  local target="${1:-}"
  if [[ -z "$target" ]]; then
    error "Usage: ./gpustack backend switch <llamacpp|ollama>"
  fi

  case "$target" in
    llamacpp|ollama) ;;
    *) error "Unknown backend '$target'. Valid options: llamacpp, ollama" ;;
  esac

  local current
  current=$(active_backend)

  if [[ "$current" == "$target" ]]; then
    warn "$target is already the active backend"
    return 0
  fi

  step "Switching backend: ${current:-none} → $target"

  # 1. Uninstall current backend (if any)
  if [[ -n "$current" ]]; then
    info "Uninstalling $current Helm release..."
    helm uninstall "$current" -n "$current" || warn "helm uninstall returned non-zero"
    success "$current Helm release removed"

    info "Deleting $current PersistentVolumeClaims (model cache)..."
    kubectl delete pvc --all -n "$current" --ignore-not-found=true
    success "$current PVCs deleted"
  fi

  # 2. Check if the target backend image is loaded in kind — build and load if not
  local target_image target_dockerfile
  case "$target" in
    llamacpp)
      target_image="$LLAMACPP_IMAGE"
      target_dockerfile="$LLAMACPP_DOCKERFILE"
      ;;
    ollama)
      target_image="$OLLAMA_IMAGE"
      target_dockerfile="$OLLAMA_DOCKERFILE"
      ;;
  esac

  local image_name="${target_image%%:*}"
  local already_loaded
  already_loaded=$(vm_ssh "podman exec ${KIND_CLUSTER_NAME}-control-plane \
    crictl images 2>/dev/null | grep -c '${image_name}'" || echo "0")

  if [[ "${already_loaded:-0}" -gt 0 ]]; then
    info "Image '$target_image' already loaded in kind — skipping build"
  else
    warn "Image '$target_image' not found in kind — building now"
    local label
    [[ "$target" == "llamacpp" ]] && label="llama.cpp" || label="Ollama"

    local image_tag="${target_image##*:}"
    local vm_tar="/root/tmp/${image_name}-${image_tag}.tar"
    local vm_build_dir="/root/tmp/${image_name}-build"

    vm_ssh "mkdir -p /root/tmp"

    [[ -f "$target_dockerfile" ]] || error "$label Dockerfile not found at $target_dockerfile"
    local build_context
    build_context="$(dirname "$target_dockerfile")"

    info "Copying $label build context into VM..."
    vm_ssh "mkdir -p $vm_build_dir"
    tar -C "$build_context" -cf - . | vm_ssh "tar -C $vm_build_dir -xf -"
    success "$label build context copied to VM"

    info "Building '$target_image' inside VM — this may take 10-20 minutes..."
    vm_ssh "podman build --device /dev/dri \
      -f ${vm_build_dir}/$(basename "$target_dockerfile") \
      -t ${target_image} \
      ${vm_build_dir}" || error "Failed to build $label image"
    success "Image '$target_image' built"

    info "Saving $label image to tar inside VM..."
    vm_ssh "podman save -o ${vm_tar} ${target_image}" || error "Failed to save $label image"

    info "Loading $label image into kind cluster..."
    vm_ssh "podman cp ${vm_tar} ${KIND_CLUSTER_NAME}-control-plane:/tmp/ && \
      podman exec ${KIND_CLUSTER_NAME}-control-plane \
        ctr -n k8s.io images import /tmp/$(basename "${vm_tar}") && \
      podman exec ${KIND_CLUSTER_NAME}-control-plane \
        rm -f /tmp/$(basename "${vm_tar}")" || error "Failed to load $label image into kind"
    success "Image '$target_image' loaded into kind"

    vm_ssh "rm -f ${vm_tar}"
  fi

  # 3. Find the Helm chart for the target backend
  local target_chart="" target_ns=""
  for i in "${!HELM_NAMES[@]}"; do
    if [[ "${HELM_NAMES[$i]}" == "$target" ]]; then
      target_chart="${HELM_CHARTS[$i]}"
      target_ns="${HELM_NAMESPACES[$i]}"
      break
    fi
  done
  [[ -z "$target_chart" ]] && error "No Helm chart found for '$target' in config.yaml"

  # 4. Ensure namespace exists
  if ! kubectl get namespace "$target_ns" &>/dev/null; then
    info "Creating namespace '$target_ns'..."
    kubectl create namespace "$target_ns"
  fi

  # 5. Install target backend
  info "Installing $target from $target_chart into namespace $target_ns..."
  helm install "$target" "$target_chart" -n "$target_ns" --timeout 3h \
    2>"/tmp/helm_err_${target}" &
  local helm_pid=$!

  sleep 5
  if ! kill -0 "$helm_pid" 2>/dev/null; then
    local helm_exit=0
    wait "$helm_pid" || helm_exit=$?
    [[ $helm_exit -ne 0 ]] && \
      error "Helm install failed for '$target': $(cat /tmp/helm_err_${target} 2>/dev/null)"
  else
    # Tail model-loader init job logs while Helm waits
    local loader_prefix="${target}-model-loader"
    local label
    [[ "$target" == "llamacpp" ]] && label="llama.cpp" || label="Ollama"
    local timeout=3600 elapsed=0
    until kubectl get pods -n "$target_ns" 2>/dev/null | grep -q "$loader_prefix"; do
      (( elapsed >= timeout )) && break
      sleep 5; (( elapsed += 5 ))
      info "  Waiting for $label model-loader pod... (${elapsed}s)"
    done
    local init_pod
    init_pod=$(kubectl get pods -n "$target_ns" --no-headers 2>/dev/null \
      | grep "$loader_prefix" | awk '{print $1}' | head -1 || true)
    if [[ -n "$init_pod" ]]; then
      info "Tailing $label model-loader logs: $init_pod"
      until kubectl get pod "$init_pod" -n "$target_ns" 2>/dev/null \
          | grep -qE "Running|Completed|Error|Succeeded"; do sleep 3; done
      kubectl logs -f "$init_pod" -n "$target_ns" 2>/dev/null || true
    fi

    local helm_exit=0
    set +e; wait "$helm_pid" 2>/dev/null; helm_exit=$?; set -e
    if [[ $helm_exit -ne 0 && $helm_exit -ne 127 ]]; then
      error "Helm install failed for '$target': $(cat /tmp/helm_err_${target} 2>/dev/null)"
    fi
  fi
  rm -f "/tmp/helm_err_${target}"
  success "$target Helm release installed"

  # 6. Wait for the new backend to be fully healthy
  _wait_for_backend_deployment "$target"

  local port
  port=$(backend_port "$target")
  echo ""
  echo -e "${GREEN}${BOLD}  Switch complete!${RESET}"
  echo -e "  ${BOLD}Active backend:${RESET} $target"
  echo -e "  ${BOLD}Endpoint:${RESET}       http://localhost:${port}"
  echo ""
}

# --- Entrypoint --------------------------------------------------------------
cmd_backend() {
  local subcmd="${1:-}"
  shift || true

  case "$subcmd" in
    start)  _backend_start ;;
    stop)   _backend_stop ;;
    status) _backend_status ;;
    logs)   _backend_logs ;;
    switch) _backend_switch "$@" ;;
    -h|--help|"") backend_help ;;
    *)
      error "Unknown subcommand: '$subcmd'"
      echo ""
      backend_help
      exit 1
      ;;
  esac
}