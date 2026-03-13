# Troubleshooting

## Table of Contents

- [Cluster unreachable after reboot](#cluster-unreachable-after-reboot)
- [kind commands fail with Docker socket error](#kind-commands-fail-with-docker-socket-error)
- [Podman machine crashes under load](#podman-machine-crashes-under-load)
- [Podman is running rootless](#podman-is-running-rootless)
- [llama-server not responding](#llama-server-not-responding)
- [llama-server falls back to CPU](#llama-server-falls-back-to-cpu-no-vulkan-device-found)
- [Model download stuck or failed](#model-download-stuck-or-failed)
- [Ollama not responding](#ollama-not-responding)
- [Check krunkit / VM logs](#check-krunkit--vm-logs)

---

## Cluster unreachable after reboot

The Podman machine and kind cluster do not start automatically. Run:

```bash
./gpustack cluster start
```

---

## kind commands fail with Docker socket error

kind needs to know to use Podman instead of Docker:

```bash
export DOCKER_HOST="unix://$(podman info --format '{{.Host.RemoteSocket.Path}}')"
export KIND_EXPERIMENTAL_PROVIDER=podman
kind get clusters
```

To set these permanently see the [Post-Installation](../README.md#post-installation) section.

---

## Podman machine crashes under load

libkrun-efi can crash the VM under heavy CPU or memory pressure. To recover:

```bash
./gpustack cluster start
```

If crashes are frequent, reduce `memory` in `config.yaml` and recreate the machine:

```bash
podman machine stop podman-machine-default
podman machine rm podman-machine-default
./gpustack setup
```

---

## Podman is running rootless

The stack requires a rootful Podman connection. If commands are failing with permission errors:

```bash
podman system connection default podman-machine-default-root
podman info --format '{{.Host.Security.Rootless}}'  # must be: false
```

---

## llama-server not responding

```bash
# Check pod status and health
./gpustack backend status

# Tail live logs
./gpustack backend logs

# Check Vulkan is working — should show "Virtio-GPU Venus"
kubectl logs -n llamacpp deployment/llamacpp | grep -i vulkan

# Check the model file exists on the PVC
kubectl exec -n llamacpp deployment/llamacpp -- ls -lh /models/
```

---

## llama-server falls back to CPU (no Vulkan device found)

```bash
# Check Vulkan device enumeration inside the pod
kubectl exec -n llamacpp deployment/llamacpp -- test-vulkan

# Verify DRI permissions were set correctly by the init container
kubectl logs -n llamacpp -l app.kubernetes.io/name=llamacpp \
  -c fix-dri-permissions
```

If Vulkan is not found, restart the Podman machine and cluster — GPU passthrough requires the machine to be started cleanly:

```bash
./gpustack cluster stop
./gpustack cluster start
```

---

## Model download stuck or failed

```bash
# Check model-loader job logs
kubectl logs -n llamacpp -l app.kubernetes.io/component=model-loader -f

# Check job status
kubectl get jobs -n llamacpp

# Re-trigger the download by deleting the job (helm upgrade recreates it)
kubectl delete job -n llamacpp -l app.kubernetes.io/component=model-loader
helm upgrade llamacpp ./helm/llamacpp -n llamacpp
```

---

## Ollama not responding

```bash
# Check pod status, health, and recent logs
./gpustack backend status

# Tail live logs
./gpustack backend logs

# Check Vulkan is working
kubectl logs -n ollama deployment/ollama | grep -i vulkan
```

---

## Check krunkit / VM logs

```bash
log show --predicate 'process == "krunkit"' --last 30m | grep -i error
```