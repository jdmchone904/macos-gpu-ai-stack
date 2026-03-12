#!/opt/homebrew/bin/bash
# =============================================================================
# lib/teardown.sh — Full stack destroy (gpustack teardown)
# =============================================================================

teardown_help() {
  echo ""
  echo -e "${BOLD}Usage:${RESET} gpustack teardown [--force]"
  echo ""
  echo -e "  Destroy the full GPU stack and uninstall all components:"
  echo -e "  Podman machines → stray processes → brew packages → config/data dirs"
  echo ""
  echo -e "${BOLD}Options:${RESET}"
  echo -e "  ${CYAN}--force${RESET}      Skip confirmation prompt"
  echo -e "  ${CYAN}-h, --help${RESET}   Show this help message"
  echo ""
  echo -e "${BOLD}Warning:${RESET}"
  echo -e "  This will permanently remove:"
  echo -e "    • Podman machine and all containers"
  echo -e "    • kind cluster"
  echo -e "    • podman, podman-desktop, kind, helm, krunkit (brew packages)"
  echo -e "    • All Podman config and data directories"
  echo ""
}

cmd_teardown() {
  local force=0
  for arg in "$@"; do
    [[ "$arg" == "--force" ]] && force=1
  done

  echo -e "${RED}${BOLD}"
  echo "  ╔═══════════════════════════════════════════════╗"
  echo "  ║   macOS GPU AI Stack — TEARDOWN               ║"
  echo "  ║   This will remove ALL stack components       ║"
  echo "  ╚═══════════════════════════════════════════════╝"
  echo -e "${RESET}"

  if [[ $force -eq 0 ]]; then
    echo -e "${YELLOW}This will uninstall:${RESET}"
    echo "  • Podman machine and all containers"
    echo "  • kind cluster"
    echo "  • podman, podman-desktop, kind, helm, krunkit"
    echo "  • All Podman config and data directories"
    echo ""
    read -r -p "  Are you sure? (yes/no): " confirm
    [[ "$confirm" == "yes" ]] || { info "Teardown cancelled."; exit 0; }
    echo ""
  fi

  # 1. Stop and remove Podman machines
  step "Stopping and removing Podman machines"
  podman machine stop --all 2>/dev/null \
    && success "All machines stopped" \
    || warn "No machines to stop"
  podman machine rm --all -f 2>/dev/null \
    && success "All machines removed" \
    || warn "No machines to remove"

  # 2. Kill stray processes
  step "Killing stray processes"
  pkill -f gvproxy 2>/dev/null && success "gvproxy killed" || warn "gvproxy not running"
  pkill -f krunkit 2>/dev/null && success "krunkit killed" || warn "krunkit not running"

  # 3. Uninstall brew packages
  step "Uninstalling brew packages"

  _uninstall_brew() {
    local pkg="$1"
    if brew list "$pkg" &>/dev/null; then
      brew uninstall --force "$pkg" && success "$pkg uninstalled"
    else
      warn "$pkg not installed — skipping"
    fi
  }

  _uninstall_brew "kind"
  _uninstall_brew "helm"
  _uninstall_brew "$KRUNKIT_PKG"
  _uninstall_brew "podman"

  if brew list --cask podman-desktop &>/dev/null; then
    brew uninstall --cask --force podman-desktop && success "podman-desktop uninstalled"
  else
    warn "podman-desktop not installed — skipping"
  fi

  brew untap "$KRUNKIT_TAP" 2>/dev/null \
    && success "$KRUNKIT_TAP tap removed" \
    || warn "$KRUNKIT_TAP tap not found"

  # 4. Remove config and data directories
  step "Removing Podman config and data directories"

  _remove_dir() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
      rm -rf "$dir" && success "Removed $dir"
    else
      warn "$dir not found — skipping"
    fi
  }

  _remove_dir "$HOME/.config/containers"
  _remove_dir "$HOME/.local/share/containers"
  _remove_dir "$HOME/.cache/containers"

  rm -rf /tmp/podman* 2>/dev/null \
    && success "Removed stray podman tmp files" || true

  # Summary
  echo ""
  echo -e "${GREEN}${BOLD}============================================${RESET}"
  echo -e "${GREEN}${BOLD}  Teardown complete!${RESET}"
  echo -e "${GREEN}${BOLD}============================================${RESET}"
  echo ""
  echo -e "  To reinstall: ${CYAN}./gpustack setup${RESET}"
  echo ""
}