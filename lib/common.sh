#!/opt/homebrew/bin/bash
# =============================================================================
# lib/common.sh — Shared colors, logging, and utility helpers
# =============================================================================

# --- Colors ------------------------------------------------------------------
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# --- Logging -----------------------------------------------------------------
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}==> $*${RESET}"; }

# --- Banner ------------------------------------------------------------------
print_banner() {
  echo -e "${BOLD}"
  echo "  ╔═══════════════════════════════════════╗"
  echo "  ║   macOS GPU Stack                     ║"
  echo "  ║   Podman + krunkit + kind + helm      ║"
  echo "  ╚═══════════════════════════════════════╝"
  echo -e "${RESET}"
}

# --- SSH into Podman VM as root ----------------------------------------------
# Requires MACHINE_NAME to be set (loaded from config)
vm_ssh() {
  local ssh_key port
  ssh_key=$(podman machine inspect "$MACHINE_NAME" --format '{{.SSHConfig.IdentityPath}}')
  port=$(podman machine inspect "$MACHINE_NAME"    --format '{{.SSHConfig.Port}}')
  ssh -i "$ssh_key" -p "$port" \
      -o StrictHostKeyChecking=no \
      -o LogLevel=ERROR \
      "root@localhost" "$@"
}

# --- Podman socket / kind env helpers ----------------------------------------
set_podman_env() {
  local podman_sock
  podman_sock=$(podman info --format '{{.Host.RemoteSocket.Path}}' 2>/dev/null || true)
  [[ -n "$podman_sock" ]] || error "Could not determine Podman socket path"
  export DOCKER_HOST="unix://${podman_sock}"
  export KIND_EXPERIMENTAL_PROVIDER=podman
}

# --- Wait helpers ------------------------------------------------------------

# wait_for_podman TIMEOUT
wait_for_podman() {
  local timeout="${1:-180}" elapsed=0
  info "Waiting for Podman machine to be ready..."
  until podman info &>/dev/null 2>&1; do
    (( elapsed >= timeout )) && error "Timed out waiting for Podman machine"
    sleep 5; (( elapsed += 5 ))
    info "  Still waiting... (${elapsed}s / ${timeout}s)"
  done
  success "Podman machine is ready"
}

# wait_for_node TIMEOUT
wait_for_node() {
  local timeout="${1:-120}" elapsed=0
  info "Waiting for cluster node to be Ready..."
  until kubectl get nodes 2>/dev/null | grep -q " Ready"; do
    (( elapsed >= timeout )) && error "Timed out waiting for cluster node"
    sleep 5; (( elapsed += 5 ))
    info "  Still waiting... (${elapsed}s / ${timeout}s)"
  done
  success "Cluster node is Ready"
}

# backend_port BACKEND → stdout
backend_port() {
  case "$1" in
    llamacpp) echo "30480" ;;
    ollama)   echo "30434"  ;;
    *)        echo "" ;;
  esac
}