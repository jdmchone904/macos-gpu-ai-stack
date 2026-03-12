#!/opt/homebrew/bin/bash
# =============================================================================
# lib/cluster.sh — Cluster start / stop / status (gpustack cluster)
# =============================================================================

cluster_help() {
  echo ""
  echo -e "${BOLD}Usage:${RESET} gpustack cluster <subcommand>"
  echo ""
  echo -e "${BOLD}Subcommands:${RESET}"
  echo -e "  ${CYAN}start${RESET}    Start Podman machine and kind cluster"
  echo -e "  ${CYAN}stop${RESET}     Stop kind cluster and Podman machine"
  echo -e "  ${CYAN}status${RESET}   Show node, pod, and Helm release status"
  echo ""
  echo -e "${BOLD}Options:${RESET}"
  echo -e "  ${CYAN}-h, --help${RESET}   Show this help message"
  echo ""
}

# --- start -------------------------------------------------------------------
_cluster_start() {
  step "Starting cluster"

  local state
  state=$(podman machine inspect "$MACHINE_NAME" --format '{{.State}}' 2>/dev/null || echo "unknown")
  if [[ "$state" == "running" ]]; then
    info "Podman machine '$MACHINE_NAME' is already running"
  else
    info "Starting Podman machine '$MACHINE_NAME'..."
    podman machine start "$MACHINE_NAME" || warn "machine start returned non-zero — checking connectivity anyway"
    podman system connection default "${MACHINE_NAME}-root"
  fi

  wait_for_podman 180

  info "Starting kind control plane node..."
  vm_ssh "podman start ${KIND_CLUSTER_NAME}-control-plane" || \
    warn "Control plane container may already be running"

  info "Refreshing kubeconfig..."
  set_podman_env
  kind export kubeconfig --name "$KIND_CLUSTER_NAME"

  wait_for_node 120
  success "Cluster is up"
}

# --- stop --------------------------------------------------------------------
_cluster_stop() {
  step "Stopping cluster"

  info "Stopping kind control plane node..."
  if vm_ssh "podman stop ${KIND_CLUSTER_NAME}-control-plane" 2>/dev/null; then
    success "Kind control plane stopped"
  else
    warn "Could not stop control plane container — it may already be stopped"
  fi

  info "Stopping Podman machine '$MACHINE_NAME'..."
  if podman machine stop "$MACHINE_NAME"; then
    success "Podman machine stopped"
  else
    warn "Podman machine stop returned non-zero — it may already be stopped"
  fi
}

# --- status ------------------------------------------------------------------
_cluster_status() {
  step "Cluster status"

  # Podman machine state
  local state
  state=$(podman machine inspect "$MACHINE_NAME" --format '{{.State}}' 2>/dev/null || echo "unknown")
  echo -e "\n  ${BOLD}Podman machine:${RESET} $MACHINE_NAME — ${CYAN}${state}${RESET}"

  if [[ "$state" != "running" ]]; then
    warn "Podman machine is not running — start with: ./gpustack cluster start"
    return 0
  fi

  set_podman_env

  # Nodes
  echo -e "\n  ${BOLD}Nodes:${RESET}"
  kubectl get nodes -o wide 2>/dev/null || warn "Could not reach cluster"

  # Pods (all namespaces)
  echo -e "\n  ${BOLD}Pods:${RESET}"
  kubectl get pods -A 2>/dev/null || warn "Could not list pods"

  # Helm releases
  echo -e "\n  ${BOLD}Helm releases:${RESET}"
  helm list -A 2>/dev/null || warn "Could not list Helm releases"

  # Backend health
  echo -e "\n  ${BOLD}Backend health:${RESET}"
  for backend in llamacpp ollama; do
    local port
    port=$(backend_port "$backend")
    if helm status "$backend" -n "$backend" &>/dev/null 2>&1; then
      if curl -sf --max-time 5 "http://localhost:${port}/health" &>/dev/null; then
        echo -e "  ${GREEN}✓${RESET} $backend   http://localhost:${port}/health"
      else
        echo -e "  ${YELLOW}~${RESET} $backend   deployed but /health not responding yet"
      fi
    else
      echo -e "  ${RED}✗${RESET} $backend   not deployed"
    fi
  done

  echo ""
}

# --- Entrypoint --------------------------------------------------------------
cmd_cluster() {
  local subcmd="${1:-}"
  shift || true

  case "$subcmd" in
    start)  _cluster_start ;;
    stop)   _cluster_stop ;;
    status) _cluster_status ;;
    -h|--help|"") cluster_help ;;
    *)
      error "Unknown subcommand: '$subcmd'"
      echo ""
      cluster_help
      exit 1
      ;;
  esac
}