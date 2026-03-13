# Operations

## Table of Contents

- [Starting and stopping](#starting-and-stopping)
- [Updating backend images](#updating-backend-images)
- [Upgrading Helm charts](#upgrading-helm-charts)
- [Recreating the kind cluster](#recreating-the-kind-cluster)
- [Recreating the Podman machine](#recreating-the-podman-machine)
- [Teardown](#teardown)

---

## Starting and stopping

### After a reboot

The Podman machine and kind cluster do not start automatically after a reboot:

```bash
./gpustack cluster start
```

### Stopping everything cleanly

```bash
./gpustack cluster stop
```

### Checking current state

```bash
./gpustack cluster status
```

This shows Podman machine state, all pod statuses, Helm releases, and a live health check against each deployed backend.

---

## Updating backend images

Both backend images are built from source inside the Podman VM. To pick up a new version of llama.cpp or Ollama, remove the existing image to force a rebuild and then re-run setup — it will skip all already-completed steps and only rebuild the image.

### llama.cpp

```bash
# Remove from kind node
podman machine ssh podman-machine-default -- \
  podman exec ai-cluster-control-plane \
  ctr -n k8s.io images rm localhost/fedora-llamacpp-vulkan:v1 2>/dev/null || true

# Remove from VM
podman machine ssh podman-machine-default -- \
  podman rmi localhost/fedora-llamacpp-vulkan:v1 2>/dev/null || true

# Rebuild
./gpustack setup

# Restart the deployment to pick up the new image
kubectl rollout restart deployment/llamacpp -n llamacpp
kubectl rollout status deployment/llamacpp -n llamacpp
```

### Pinning a specific llama.cpp version

Edit `llama-cpp/macos/Dockerfile` and change the clone line:

```dockerfile
# Latest (default):
RUN git clone --depth 1 https://github.com/ggml-org/llama.cpp.git /llama.cpp

# Pinned to a specific tag:
RUN git clone --branch b5140 --depth 1 https://github.com/ggml-org/llama.cpp.git /llama.cpp
```

### Ollama

```bash
# Remove from kind node
podman machine ssh podman-machine-default -- \
  podman exec ai-cluster-control-plane \
  ctr -n k8s.io images rm docker.io/library/fedora-ollama-vulkan:v1 2>/dev/null || true

# Remove from VM
podman machine ssh podman-machine-default -- \
  podman rmi fedora-ollama-vulkan:v1 2>/dev/null || true

# Rebuild
./gpustack setup

# Restart the deployment
kubectl rollout restart deployment/ollama -n ollama
kubectl rollout status deployment/ollama -n ollama
```

---

## Upgrading Helm charts

```bash
helm upgrade llamacpp ./helm/llamacpp -n llamacpp
helm upgrade ollama   ./helm/ollama   -n ollama
helm upgrade n8n      ./helm/n8n      -n n8n
```

### Rollback and history

```bash
helm rollback llamacpp -n llamacpp
helm history llamacpp  -n llamacpp
```

---

## Recreating the kind cluster

Required when adding or removing port mappings, or when the cluster becomes unrecoverable:

```bash
export DOCKER_HOST="unix://$(podman info --format '{{.Host.RemoteSocket.Path}}')"
export KIND_EXPERIMENTAL_PROVIDER=podman
kind delete cluster --name ai-cluster
./gpustack setup
```

> Setup will skip tool installation and the Podman machine, and go straight to recreating the cluster, reloading images, and reinstalling Helm charts.

---

## Recreating the Podman machine

Required when changing CPU, memory, or disk in `config.yaml`, or after a krunkit upgrade:

```bash
podman machine stop podman-machine-default
podman machine rm podman-machine-default
./gpustack setup
```

> **Warning:** This destroys the kind cluster and all loaded images. Downloaded models on PersistentVolumes are preserved if `helm.sh/resource-policy: keep` is set on the PVCs (default in this stack).

---

## Teardown

To completely remove the stack and all installed components:

```bash
./gpustack teardown
```

Add `--force` to skip the confirmation prompt:

```bash
./gpustack teardown --force
```

This will permanently remove:
- Podman machine and all containers
- kind cluster
- `podman`, `podman-desktop`, `kind`, `helm`, `krunkit` (brew packages and tap)
- All Podman config and data directories (`~/.config/containers`, `~/.local/share/containers`, `~/.cache/containers`)
- Stray `gvproxy` and `krunkit` processes

> **Warning:** This is destructive and irreversible. All containers, images, volumes, cluster data, and downloaded models will be permanently deleted.