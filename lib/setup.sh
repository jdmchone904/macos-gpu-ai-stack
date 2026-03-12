#!/opt/homebrew/bin/bash
# =============================================================================
# lib/setup.sh — Full stack install (gpustack setup)
# =============================================================================

setup_help() {
  echo ""
  echo -e "${BOLD}Usage:${RESET} gpustack setup"
  echo ""
  echo -e "  Install and configure the full GPU stack:"
  echo -e "  krunkit → Podman machine → kind cluster → images → Helm charts"
  echo ""
  echo -e "${BOLD}Options:${RESET}"
  echo -e "  ${CYAN}-h, --help${RESET}   Show this help message"
  echo ""
  echo -e "${BOLD}Environment:${RESET}"
  echo -e "  ${CYAN}GPUSTACK_CONFIG${RESET}  Path to config.yaml (default: ./config.yaml)"
  echo ""
}

# --- Prerequisites -----------------------------------------------------------
_check_prerequisites() {
  step "Checking prerequisites"
  command -v brew &>/dev/null || error "Homebrew not found. Install from https://brew.sh"
  success "Homebrew found"

  [[ -f "$KIND_CONFIG" ]] || error "kind config not found at $KIND_CONFIG"
  success "kind config found: $KIND_CONFIG"

  if backend_enabled "ollama"; then
    [[ -f "$OLLAMA_DOCKERFILE" ]] || error "Ollama Dockerfile not found at $OLLAMA_DOCKERFILE"
    success "Ollama Dockerfile found: $OLLAMA_DOCKERFILE"
  fi

  if backend_enabled "llamacpp"; then
    [[ -f "$LLAMACPP_DOCKERFILE" ]] || \
      error "llama.cpp Dockerfile not found at $LLAMACPP_DOCKERFILE"
    success "llama.cpp Dockerfile found: $LLAMACPP_DOCKERFILE"
  fi

  for i in "${!HELM_NAMES[@]}"; do
    local name="${HELM_NAMES[$i]}"
    if [[ "$name" == "ollama"   ]] && ! backend_enabled "ollama";   then continue; fi
    if [[ "$name" == "llamacpp" ]] && ! backend_enabled "llamacpp"; then continue; fi
    [[ -d "${HELM_CHARTS[$i]}" ]] || \
      error "Helm chart '$name' not found at ${HELM_CHARTS[$i]}"
    success "Helm chart found: $name → ${HELM_CHARTS[$i]}"
  done
}

# --- Tool install ------------------------------------------------------------
_install_brew_pkg() {
  local cmd="$1" pkg="${2:-$1}" cask="${3:-}"
  if command -v "$cmd" &>/dev/null; then
    warn "$cmd already installed — skipping"; return 0
  fi
  info "Installing $cmd..."
  [[ "$cask" == "cask" ]] && brew install --cask "$pkg" || brew install "$pkg"
  success "$cmd installed"
}

_install_tools() {
  step "Installing required tools"
  if command -v krunkit &>/dev/null; then
    warn "krunkit already installed — skipping"
  else
    info "Installing krunkit via brew tap $KRUNKIT_TAP..."
    brew tap "$KRUNKIT_TAP"
    brew install "$KRUNKIT_PKG"
    success "krunkit installed"
  fi
  _install_brew_pkg "podman"
  _install_brew_pkg "podman-desktop" "podman-desktop" "cask"
  _install_brew_pkg "kind"
  _install_brew_pkg "helm"
}

# --- Podman machine ----------------------------------------------------------
_setup_podman_machine() {
  step "Setting up Podman machine"

  if podman machine list --format '{{.Name}}' 2>/dev/null | sed 's/\*$//' | grep -q "^${MACHINE_NAME}$"; then
    local config_dir
    config_dir=$(podman machine inspect "$MACHINE_NAME" 2>/dev/null \
      | grep -i '"Path"' | head -1 | tr -d ' ",' | cut -d: -f2)
    if echo "$config_dir" | grep -q "applehv"; then
      error "Podman machine '$MACHINE_NAME' uses applehv (no GPU passthrough). Remove it and re-run:
       podman machine stop $MACHINE_NAME && podman machine rm $MACHINE_NAME
       ./gpustack setup"
    fi
    warn "Podman machine '$MACHINE_NAME' already exists — skipping init"
  else
    local containers_conf="$HOME/.config/containers/containers.conf"
    if [[ ! -f "$containers_conf" ]] || ! grep -q "provider.*libkrun" "$containers_conf"; then
      info "Configuring Podman to use libkrun provider..."
      mkdir -p "$(dirname "$containers_conf")"
      cat > "$containers_conf" << 'EOF'
[machine]
provider = "libkrun"
EOF
      success "Podman provider set to libkrun"
    fi
    info "Creating Podman machine '$MACHINE_NAME'..."
    podman machine init \
      --cpus      "$MACHINE_CPU" \
      --memory    "$MACHINE_MEM" \
      --disk-size "$MACHINE_DISK" \
      --rootful \
      "$MACHINE_NAME"
    success "Podman machine '$MACHINE_NAME' created"
  fi

  local state
  state=$(podman machine inspect "$MACHINE_NAME" --format '{{.State}}' 2>/dev/null || echo "unknown")
  if [[ "$state" == "running" ]]; then
    info "Podman machine '$MACHINE_NAME' is already running"
  else
    info "Starting Podman machine '$MACHINE_NAME'..."
    podman machine start "$MACHINE_NAME" || warn "machine start returned non-zero — checking connectivity anyway"
  fi

  info "Setting rootful connection as default..."
  podman system connection default "${MACHINE_NAME}-root" 2>/dev/null || \
    error "Could not set rootful connection '${MACHINE_NAME}-root'. Run: podman system connection list"

  local rootless
  rootless=$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || echo "unknown")
  [[ "$rootless" == "false" ]] || \
    error "Podman is still running rootless. Check: podman system connection list"
  success "Podman is running rootful"

  wait_for_podman 180
}

# --- kind cluster ------------------------------------------------------------
_setup_kind_cluster() {
  step "Setting up kind cluster"
  set_podman_env
  info "Using Podman socket: $DOCKER_HOST"

  if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
    warn "kind cluster '$KIND_CLUSTER_NAME' already exists — skipping"
  else
    info "Creating kind cluster '$KIND_CLUSTER_NAME'..."
    kind create cluster --config "$KIND_CONFIG" --name "$KIND_CLUSTER_NAME"
    success "kind cluster '$KIND_CLUSTER_NAME' created"
  fi

  wait_for_node 120
}

# --- Image build/load --------------------------------------------------------
_build_and_load_image() {
  local image="$1" dockerfile="$2" label="$3"
  local image_name="${image%%:*}"
  local image_tag="${image##*:}"
  local vm_tar="/root/tmp/${image_name}-${image_tag}.tar"
  local vm_build_dir="/root/tmp/${image_name}-build"

  vm_ssh "mkdir -p /root/tmp"

  local already_loaded
  already_loaded=$(vm_ssh "podman exec ${KIND_CLUSTER_NAME}-control-plane \
    crictl images 2>/dev/null | grep -c '${image_name}'" || echo "0")
  if [[ "${already_loaded:-0}" -gt 0 ]]; then
    warn "Image '$image' already loaded in kind — skipping ($label)"
    return 0
  fi

  [[ -f "$dockerfile" ]] || error "$label Dockerfile not found at $dockerfile"
  local build_context
  build_context="$(dirname "$dockerfile")"

  info "Copying $label build context into VM ($build_context)..."
  vm_ssh "mkdir -p $vm_build_dir"
  tar -C "$build_context" -cf - . | vm_ssh "tar -C $vm_build_dir -xf -"
  success "$label build context copied to VM"

  info "Building '$image' inside VM ($label) — this may take 10-20 minutes..."
  vm_ssh "podman build --device /dev/dri \
    -f ${vm_build_dir}/$(basename "$dockerfile") \
    -t ${image} \
    ${vm_build_dir}" || error "Failed to build $label image"
  success "Image '$image' built ($label)"

  info "Saving $label image to tar inside VM..."
  vm_ssh "podman save -o ${vm_tar} ${image}" || error "Failed to save $label image"
  success "$label image saved"

  info "Loading $label image into kind cluster..."
  vm_ssh "podman cp ${vm_tar} ${KIND_CLUSTER_NAME}-control-plane:/tmp/ && \
    podman exec ${KIND_CLUSTER_NAME}-control-plane \
      ctr -n k8s.io images import /tmp/$(basename "${vm_tar}") && \
    podman exec ${KIND_CLUSTER_NAME}-control-plane \
      rm -f /tmp/$(basename "${vm_tar}")" || error "Failed to load $label image into kind"
  success "Image '$image' loaded into kind cluster ($label)"

  vm_ssh "rm -f ${vm_tar}"
}

# --- Namespaces --------------------------------------------------------------
_create_namespaces() {
  step "Creating Kubernetes namespaces"
  for ns in "${NAMESPACES[@]}"; do
    if kubectl get namespace "$ns" &>/dev/null; then
      warn "Namespace '$ns' already exists — skipping"
    else
      kubectl create namespace "$ns"
      success "Namespace '$ns' created"
    fi
  done
}

# --- Helm --------------------------------------------------------------------
_tail_init_logs() {
  local ns="$1" pod_prefix="$2" label="$3"
  local timeout=3600 elapsed=0

  info "Waiting for $label init job pod to start..."
  until kubectl get pods -n "$ns" 2>/dev/null | grep -q "$pod_prefix"; do
    (( elapsed >= timeout )) && warn "Timed out waiting for $label init pod — skipping log tail" && return 0
    sleep 5; (( elapsed += 5 ))
    info "  Still waiting for $label init pod... (${elapsed}s / ${timeout}s)"
  done

  local init_pod
  init_pod=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null \
    | grep "$pod_prefix" | awk '{print $1}' | head -1)
  [[ -z "$init_pod" ]] && warn "Could not find $label init pod — skipping log tail" && return 0

  info "Tailing $label init pod logs: $init_pod"
  info "  (This may take several minutes depending on model size and internet speed)"
  echo ""

  until kubectl get pod "$init_pod" -n "$ns" 2>/dev/null | grep -qE "Running|Completed|Error|Succeeded"; do
    sleep 3
  done
  kubectl logs -f "$init_pod" -n "$ns" 2>/dev/null || true
  echo ""
  success "$label init job completed"
}

_install_helm_charts() {
  step "Installing Helm charts"
  for i in "${!HELM_NAMES[@]}"; do
    local name="${HELM_NAMES[$i]}"
    local chart="${HELM_CHARTS[$i]}"
    local ns="${HELM_NAMESPACES[$i]}"

    if [[ "$name" == "ollama"   ]] && ! backend_enabled "ollama";   then
      info "Skipping Helm release '$name' — ollama not selected"; continue
    fi
    if [[ "$name" == "llamacpp" ]] && ! backend_enabled "llamacpp"; then
      info "Skipping Helm release '$name' — llamacpp not selected"; continue
    fi

    if helm status "$name" -n "$ns" &>/dev/null; then
      warn "Helm release '$name' already exists in '$ns' — skipping install"
      case "$name" in ollama|llamacpp) _restart_and_verify ;; esac
      continue
    fi

    info "Installing '$name' from $chart into namespace '$ns'..."
    helm install "$name" "$chart" -n "$ns" --timeout 3h \
      2>"/tmp/helm_err_${name}" &
    local helm_pid=$!

    sleep 5
    if ! kill -0 "$helm_pid" 2>/dev/null; then
      local helm_exit=0
      wait "$helm_pid" || helm_exit=$?
      [[ $helm_exit -ne 0 ]] && \
        error "Helm install failed for '$name': $(cat /tmp/helm_err_${name} 2>/dev/null)"
      rm -f "/tmp/helm_err_${name}"
      success "Helm release '$name' installed"
    else
      case "$name" in
        ollama)   _tail_init_logs "$ns" "ollama-model-loader"   "Ollama" ;;
        llamacpp) _tail_init_logs "$ns" "llamacpp-model-loader" "llama.cpp" ;;
      esac

      local helm_exit=0
      set +e; wait "$helm_pid" 2>/dev/null; helm_exit=$?; set -e
      if [[ $helm_exit -ne 0 && $helm_exit -ne 127 ]]; then
        error "Helm install failed for '$name': $(cat /tmp/helm_err_${name} 2>/dev/null)"
      fi
      rm -f "/tmp/helm_err_${name}"
      success "Helm release '$name' installed"
    fi

    case "$name" in ollama|llamacpp) _restart_and_verify ;; esac
  done
}

# --- Restart and verify ------------------------------------------------------
_restart_and_verify() {
  step "Restarting Podman machine and cluster"

  info "Stopping Podman machine..."
  podman machine stop "$MACHINE_NAME"
  info "Starting Podman machine..."
  podman machine start "$MACHINE_NAME" || warn "machine start returned non-zero — checking connectivity anyway"
  info "Setting rootful connection as default..."
  podman system connection default "${MACHINE_NAME}-root"

  wait_for_podman 180

  info "Starting kind control plane node..."
  vm_ssh "podman start ${KIND_CLUSTER_NAME}-control-plane" || \
    warn "Could not start control plane container — it may already be running"

  info "Refreshing kubeconfig..."
  set_podman_env
  kind export kubeconfig --name "$KIND_CLUSTER_NAME"

  wait_for_node 120

  # Wait for any already-deployed backends to come back healthy
  for backend in "llamacpp" "ollama"; do
    if backend_enabled "$backend"; then
      if kubectl get deployment "$backend" -n "$backend" &>/dev/null 2>&1; then
        source "$LIB_DIR/backend.sh"
        _wait_for_backend_deployment "$backend"
      fi
    fi
  done
}

# --- Summary -----------------------------------------------------------------
_print_summary() {
  echo ""
  echo -e "${GREEN}${BOLD}============================================${RESET}"
  echo -e "${GREEN}${BOLD}  Setup complete!${RESET}"
  echo -e "${GREEN}${BOLD}============================================${RESET}"
  echo ""
  echo -e "  ${BOLD}Podman machine:${RESET}  $MACHINE_NAME"
  echo -e "  ${BOLD}Kind cluster:${RESET}    $KIND_CLUSTER_NAME"
  backend_enabled "ollama"   && echo -e "  ${BOLD}Ollama image:${RESET}    $OLLAMA_IMAGE"
  backend_enabled "llamacpp" && echo -e "  ${BOLD}llama.cpp image:${RESET} $LLAMACPP_IMAGE"
  echo -e "  ${BOLD}Namespaces:${RESET}      ${NAMESPACES[*]}"
  echo -e "  ${BOLD}Helm releases:${RESET}"
  for i in "${!HELM_NAMES[@]}"; do
    echo -e "    • ${HELM_NAMES[$i]} → ${HELM_NAMESPACES[$i]}"
  done
  echo ""
  echo -e "  ${CYAN}Endpoints:${RESET}"
  backend_enabled "ollama"   && echo -e "    Ollama:     http://localhost:30434"
  backend_enabled "llamacpp" && echo -e "    llama.cpp:  http://localhost:30480"
  echo -e "    n8n:        http://localhost:30678"
  echo ""
  echo -e "  ${CYAN}./gpustack cluster status${RESET}   — check all pods and releases"
  echo ""
}

# --- Entrypoint --------------------------------------------------------------
# load_config and prompt_backends are called by the dispatcher before cmd_setup,
# so this function only needs to run the actual install steps.
cmd_setup() {
  print_banner
  _check_prerequisites
  _install_tools
  _setup_podman_machine
  _setup_kind_cluster
  if backend_enabled "ollama"; then
    _build_and_load_image "$OLLAMA_IMAGE"   "$OLLAMA_DOCKERFILE"   "Ollama"
  fi
  if backend_enabled "llamacpp"; then
    _build_and_load_image "$LLAMACPP_IMAGE" "$LLAMACPP_DOCKERFILE" "llama.cpp"
  fi
  _create_namespaces
  _install_helm_charts
  _print_summary
}

# check_prerequisites is called by the dispatcher so it needs to be public
check_prerequisites() { _check_prerequisites; }