#!/opt/homebrew/bin/bash
# =============================================================================
# lib/config.sh — Config file parsing and backend selection
# =============================================================================

# --- YAML helpers ------------------------------------------------------------

# get_yaml_value FILE SECTION KEY
get_yaml_value() {
  local file="$1" section="$2" key="$3"
  awk -v section="$section" -v key="$key" '
    $0 ~ "^"section":"          { in_section=1; next }
    in_section && /^[a-zA-Z]/  { in_section=0 }
    in_section && $0 ~ "^[[:space:]]+"key":" {
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "")
      gsub(/"/, "")
      print; exit
    }
  ' "$file"
}

# get_yaml_list FILE TOP_KEY
get_yaml_list() {
  local file="$1" key="$2"
  awk -v key="$key" '
    $0 ~ "^"key":"              { found=1; next }
    found && /^[a-zA-Z]/       { exit }
    found && /^[[:space:]]*-[[:space:]]/ {
      sub(/^[[:space:]]*-[[:space:]]*/, "")
      gsub(/"/, "")
      print
    }
  ' "$file"
}

# load_helm_releases FILE
load_helm_releases() {
  local file="$1"
  HELM_NAMES=(); HELM_CHARTS=(); HELM_NAMESPACES=()

  local parsed
  parsed=$(awk '
    /^helm:/        { in_helm=1; next }
    in_helm && /^[a-zA-Z]/ && !/^[[:space:]]/ { in_helm=0; in_rel=0; next }
    in_helm && /releases:/ { in_rel=1; next }
    in_rel && /^[[:space:]]+-[[:space:]]*$/ {
      if (name != "") print name "|" chart "|" ns
      name=""; chart=""; ns=""; next
    }
    in_rel && /^[[:space:]]+-[[:space:]]+name:/ {
      if (name != "") print name "|" chart "|" ns
      name=""; chart=""; ns=""
      sub(/.*name:[[:space:]]*/, ""); gsub(/"/, ""); name=$0; next
    }
    in_rel && /^[[:space:]]+name:/ {
      sub(/.*name:[[:space:]]*/, ""); gsub(/"/, ""); name=$0; next
    }
    in_rel && /^[[:space:]]+-[[:space:]]+chart:/ {
      sub(/.*chart:[[:space:]]*/, ""); gsub(/"/, ""); chart=$0; next
    }
    in_rel && /^[[:space:]]+chart:/ {
      sub(/.*chart:[[:space:]]*/, ""); gsub(/"/, ""); chart=$0; next
    }
    in_rel && /^[[:space:]]+-[[:space:]]+namespace:/ {
      sub(/.*namespace:[[:space:]]*/, ""); gsub(/"/, ""); ns=$0; next
    }
    in_rel && /^[[:space:]]+namespace:/ {
      sub(/.*namespace:[[:space:]]*/, ""); gsub(/"/, ""); ns=$0; next
    }
    END { if (name != "") print name "|" chart "|" ns }
  ' "$file")

  while IFS='|' read -r name chart ns; do
    [[ -z "$name" ]] && continue
    HELM_NAMES+=("$name")
    HELM_CHARTS+=("$SCRIPT_DIR/$chart")
    HELM_NAMESPACES+=("$ns")
  done <<< "$parsed"

  for i in "${!HELM_NAMES[@]}"; do
    info "  Helm release parsed: name=${HELM_NAMES[$i]} ns=${HELM_NAMESPACES[$i]} chart=${HELM_CHARTS[$i]}"
  done
}

# --- Backend selection -------------------------------------------------------

# prompt_backends — interactive selection, sets ENABLED_BACKENDS
prompt_backends() {
  echo ""
  echo -e "${BOLD}  Which inference backend would you like to install?${RESET}"
  echo -e "  ${CYAN}1)${RESET} llama.cpp  ${CYAN}[default]${RESET}"
  echo -e "  ${CYAN}2)${RESET} Ollama"
  echo ""
  read -r -p "  Enter choice [1]: " choice
  choice="${choice:-1}"

  case "$choice" in
    1) ENABLED_BACKENDS=("llamacpp"); info "Installing: llama.cpp" ;;
    2) ENABLED_BACKENDS=("ollama");   info "Installing: Ollama" ;;
    *)
      warn "Invalid choice '$choice' — defaulting to llama.cpp"
      ENABLED_BACKENDS=("llamacpp")
      ;;
  esac
  echo ""
}

# backend_enabled TARGET — returns 0 if TARGET is in ENABLED_BACKENDS
backend_enabled() {
  local target="$1"
  for b in "${ENABLED_BACKENDS[@]}"; do
    [[ "$b" == "$target" ]] && return 0
  done
  return 1
}

# active_backend — prints the currently deployed backend (llamacpp or ollama)
# by checking which helm release exists in-cluster
active_backend() {
  for b in llamacpp ollama; do
    if helm status "$b" -n "$b" &>/dev/null 2>&1; then
      echo "$b"; return 0
    fi
  done
  echo ""
}

# --- Main config loader ------------------------------------------------------
load_config() {
  [[ -f "$CONFIG_FILE" ]] || error "Config file not found at: $CONFIG_FILE"
  info "Loading config from: $CONFIG_FILE"

  MACHINE_NAME=$(get_yaml_value "$CONFIG_FILE" "podman"  "machine_name")
  MACHINE_CPU=$( get_yaml_value "$CONFIG_FILE" "podman"  "cpu")
  MACHINE_MEM=$( get_yaml_value "$CONFIG_FILE" "podman"  "memory")
  MACHINE_DISK=$(get_yaml_value "$CONFIG_FILE" "podman"  "disk")

  KIND_CONFIG="$SCRIPT_DIR/$(get_yaml_value "$CONFIG_FILE" "paths" "kind_config")"
  KIND_CLUSTER_NAME=$(get_yaml_value "$CONFIG_FILE" "kind"    "cluster_name")

  KRUNKIT_TAP=$(get_yaml_value "$CONFIG_FILE" "krunkit" "brew_tap")
  KRUNKIT_PKG=$(get_yaml_value "$CONFIG_FILE" "krunkit" "brew_pkg")

  OLLAMA_IMAGE=$(get_yaml_value "$CONFIG_FILE" "ollama" "image")
  OLLAMA_DOCKERFILE="$SCRIPT_DIR/$(get_yaml_value "$CONFIG_FILE" "paths" "ollama_dockerfile")"

  LLAMACPP_IMAGE=$(get_yaml_value "$CONFIG_FILE" "llamacpp" "image")
  LLAMACPP_DOCKERFILE="$SCRIPT_DIR/$(get_yaml_value "$CONFIG_FILE" "paths" "llamacpp_dockerfile")"

  NAMESPACES=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && NAMESPACES+=("$line")
  done < <(get_yaml_list "$CONFIG_FILE" "namespaces")

  load_helm_releases "$CONFIG_FILE"

  local missing=()
  [[ -z "$MACHINE_NAME"        ]] && missing+=("podman.machine_name")
  [[ -z "$MACHINE_CPU"         ]] && missing+=("podman.cpu")
  [[ -z "$MACHINE_MEM"         ]] && missing+=("podman.memory")
  [[ -z "$MACHINE_DISK"        ]] && missing+=("podman.disk")
  [[ -z "$KIND_CLUSTER_NAME"   ]] && missing+=("kind.cluster_name")
  [[ -z "$OLLAMA_IMAGE"        ]] && missing+=("ollama.image")
  [[ -z "$OLLAMA_DOCKERFILE"   ]] && missing+=("paths.ollama_dockerfile")
  [[ -z "$LLAMACPP_IMAGE"      ]] && missing+=("llamacpp.image")
  [[ -z "$LLAMACPP_DOCKERFILE" ]] && missing+=("paths.llamacpp_dockerfile")
  [[ ${#missing[@]} -gt 0 ]] && error "Config missing required fields: ${missing[*]}"

  success "Config loaded"
  info "  Machine:    $MACHINE_NAME (${MACHINE_CPU} cpu, ${MACHINE_MEM}MB, ${MACHINE_DISK}GB)"
  info "  Cluster:    $KIND_CLUSTER_NAME"
  info "  Namespaces: ${NAMESPACES[*]}"
  info "  Helm:       ${HELM_NAMES[*]}"
}