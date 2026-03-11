# macos-gpu-ai-stack
### Kubernetes on Podman with GPU-accelerated llama.cpp and n8n

This stack runs a local Kubernetes cluster on macOS using Podman with GPU passthrough via krunkit/libkrun-efi, giving llama.cpp and Ollama access to the host's Metal GPU instead of falling back to CPU inference.

### Why run llama.cpp in Kubernetes instead of natively?

Running llama.cpp natively on macOS via Metal will always be faster. However, the goal of this stack is not raw performance — it's to provide a **reliable, isolated, and extensible local AI platform** that you can build on top of.

By running inside Kubernetes you get:
- **Isolation** — models and services run in containers with defined resource limits, keeping your Mac environment clean
- **Extensibility** — easily add services alongside llama.cpp such as n8n for workflow automation, Open WebUI for a chat interface, custom model training pipelines, full stack application testing, or any other containerized workload
- **Reproducibility** — the entire stack is defined as code and can be spun up from scratch on any Apple Silicon Mac with a single script
- **Service networking** — all services communicate via Kubernetes DNS, making it easy to wire up complex multi-service AI workflows

### llama.cpp vs Ollama — which should you use?

**Use llama.cpp** (`llama-server`) for best performance. It has a lower overhead path to the GPU and consistently outperforms Ollama in this stack.

**Use Ollama** if you need its specific model management features (`ollama pull`, Modelfile customisation) or are integrating with tools that target the Ollama API specifically.

The setup script will ask you which backend to install at runtime. You can install one or both.

### Performance expectations

Due to the GPU passthrough path (Vulkan → virtio-gpu → krunkit → Metal), you can expect roughly **60-70%+ of native Metal performance**. Benchmarks below were run on an **M3 Pro** and show llama.cpp outperforming Ollama across all model sizes.

#### llama.cpp (llama-server, Vulkan via krunkit)

| Model | Size | Avg Tokens/sec | Native Metal M3 Pro (est.) | % of Native |
|---|---|---|---|---|
| llama3.2 | 3B | ~55.3 tok/s | ~90–110 tok/s | ~55–60% |
| mistral | 7B | ~28.4 tok/s | ~30–35 tok/s | ~85–90% |
| gpt-oss:20b | 20B | ~43.9 tok/s | ~60–70 tok/s | ~65–70% |

#### Ollama (Vulkan via krunkit)

| Model | Size | Avg Tokens/sec | Native Metal M3 Pro (est.) | % of Native |
|---|---|---|---|---|
| llama3.2 | 3B | ~49 tok/s | ~90–110 tok/s | ~50–55% |
| mistral | 7B | ~26 tok/s | ~30–35 tok/s | ~80–85% |
| gpt-oss:20b | 20B | ~27 tok/s | ~60–70 tok/s | ~40–45% |

> Benchmarks run on an M3 Pro using prompt "Write a story about a robot." llama.cpp is the recommended backend — it outperforms Ollama across all model sizes, with the largest gain on gpt-oss:20b (43.9 vs 27 tok/s, +63%).
>
> **Native Metal figures** are community-sourced estimates for llama.cpp running directly on macOS Metal (no VM/container). llama3.2 3B is very lightweight and saturates the M3 Pro's bandwidth at high tok/s; mistral 7B (Q4\_K\_M) benefits from the full 150 GB/s bandwidth and runs near-natively even through Vulkan; gpt-oss:20b is a MoE model (only ~3.6B parameters active per token) whose performance scales with memory bandwidth. Native figures assume full Metal acceleration with all layers GPU-offloaded (`-ngl 99`).

For most local AI development and automation workflows this performance level is more than sufficient, and the benefits of a fully containerised, reproducible environment outweigh the performance tradeoff.

### Components

- **Podman** — container engine (replaces Docker)
- **krunkit + libkrun-efi** — hypervisor that enables GPU passthrough from macOS to the VM
- **kind** — Kubernetes cluster running inside the Podman VM
- **llama.cpp** — high-performance LLM inference server with Vulkan/GPU acceleration (recommended)
- **Ollama** — alternative LLM inference server with Vulkan/GPU acceleration
- **n8n** — workflow automation platform

---

## Prerequisites

### Hardware
- Apple Silicon Mac (M1 or later)
- macOS Sequoia 15.0 or later
- 16GB RAM minimum (24GB+ recommended)

### Software
Install Homebrew if not already installed:
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Install Bash 4+ (macOS ships with Bash 3):
```bash
brew install bash
```

---

## Installation

### 1. Clone the repository
```bash
git clone <your-repo-url>
cd <your-repo>
```

### 2. Review config.yaml
Adjust resources to match your machine. Recommended starting point:

```yaml
podman:
  machine_name: podman-machine-default
  cpu: 8
  memory: 16384       # 16GB — reduce if you experience VM instability
  disk: 100

krunkit:
  brew_tap: slp/krunkit
  brew_pkg: slp/krunkit/krunkit

kind:
  cluster_name: ai-cluster

backends:
  - llamacpp   # default — recommended for best performance
  # - ollama   # uncomment to install Ollama instead or as well

llamacpp:
  image: "fedora-llamacpp-vulkan:v1"

ollama:
  image: "fedora-ollama-vulkan:v1"

namespaces:
  - llamacpp
  - ollama
  - n8n

paths:
  kind_config:         "kind/kind-config.yaml"
  llamacpp_dockerfile: "llama-cpp/macos/Dockerfile"
  ollama_dockerfile:   "ollama/macos/Dockerfile"

helm:
  releases:
    - name:      "llamacpp"
      chart:     "./helm/llamacpp"
      namespace: "llamacpp"
    - name:      "ollama"
      chart:     "./helm/ollama"
      namespace: "ollama"
    - name:      "n8n"
      chart:     "./helm/n8n"
      namespace: "n8n"
```

> **Note on memory:** libkrun-efi can crash the VM under heavy memory pressure. If you experience instability, reduce `memory` in `config.yaml` and recreate the machine. 16384 (16GB) is a stable value on a 36GB host.

### 3. Review kind/kind-config.yaml
Port mappings are set at cluster creation time and cannot be changed without recreating the cluster. Add all ports you need upfront:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ai-cluster
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: /dev/dri
        containerPath: /dev/dri
        propagation: HostToContainer
    extraPortMappings:
      - containerPort: 30480    # llama-server NodePort
        hostPort: 30480
        protocol: TCP
      - containerPort: 30434    # Ollama NodePort
        hostPort: 30434
        protocol: TCP
      - containerPort: 30678    # n8n NodePort
        hostPort: 30678
        protocol: TCP
      - containerPort: 80       # HTTP ingress
        hostPort: 8080
        protocol: TCP
      - containerPort: 443      # HTTPS ingress
        hostPort: 8443
        protocol: TCP
```

### 4. Review helm/llamacpp/values.yaml
Configure which models to download and serve:

```yaml
models:
  - name: "gpt-oss-20b"
    hf_repo: "bartowski/openai_gpt-oss-20b-GGUF"
    filename: "openai_gpt-oss-20b-MXFP4.gguf"
  - name: "mistral-7b"
    hf_repo: "bartowski/Mistral-7B-Instruct-v0.3-GGUF"
    filename: "Mistral-7B-Instruct-v0.3-Q4_K_M.gguf"
  - name: "llama3.2-3b"
    hf_repo: "bartowski/Llama-3.2-3B-Instruct-GGUF"
    filename: "Llama-3.2-3B-Instruct-Q4_K_M.gguf"
```

> **Recommendation:** During initial setup, comment out large models (20B+) and add them after setup via `helm upgrade` to avoid long waits during install.

### 5. Run the setup script
```bash
/opt/homebrew/bin/bash setup.sh
```

The script will prompt you to choose which backend(s) to install:
```
  Which inference backends would you like to install?
  1) llama.cpp only  [default]
  2) Ollama only
  3) Both llama.cpp and Ollama

  Enter choice [1]:
```

The script will then:
1. Install Podman, kind, helm, krunkit, and libkrun-efi via Homebrew
2. Create and start the Podman VM with GPU passthrough enabled
3. Set the rootful Podman connection as default
4. Create the kind Kubernetes cluster
5. Build and load the selected backend image(s) into the cluster
6. Create Kubernetes namespaces
7. Install Helm charts and download models

> The first run takes 20–40 minutes depending on your internet connection and chosen models. Subsequent runs skip already-completed steps.

---

## Post-Installation

### Set environment variables permanently
kind and Docker tooling need to know to use Podman instead of Docker. Add these to your shell profile:

```bash
# For zsh (default on macOS)
echo '' >> ~/.zshrc
echo '# Podman/kind configuration' >> ~/.zshrc
echo 'export KIND_EXPERIMENTAL_PROVIDER=podman' >> ~/.zshrc
echo 'export DOCKER_HOST="unix://$(podman info --format '\''{{.Host.RemoteSocket.Path}}'\'' 2>/dev/null)"' >> ~/.zshrc
source ~/.zshrc
```

```bash
# For bash
echo '' >> ~/.bash_profile
echo '# Podman/kind configuration' >> ~/.bash_profile
echo 'export KIND_EXPERIMENTAL_PROVIDER=podman' >> ~/.bash_profile
echo 'export DOCKER_HOST="unix://$(podman info --format '\''{{.Host.RemoteSocket.Path}}'\'' 2>/dev/null)"' >> ~/.bash_profile
source ~/.bash_profile
```

### Verify the installation
```bash
# Check Podman is rootful
podman info --format '{{.Host.Security.Rootless}}'   # must be: false

# Check cluster is running
kubectl get nodes
kubectl get pods -A

# Check Helm releases
helm list -A
```

### Verify endpoints are reachable
```bash
# llama.cpp
curl http://localhost:30480/health

# Ollama (if installed)
curl http://localhost:30434/api/tags

# n8n — open in browser
open http://localhost:30678
```

---

## Starting, Stopping and Restarting the Stack

Use `cluster.sh` to manage the stack after initial setup:

```bash
/opt/homebrew/bin/bash cluster.sh start
/opt/homebrew/bin/bash cluster.sh stop
/opt/homebrew/bin/bash cluster.sh restart
/opt/homebrew/bin/bash cluster.sh status
```

---

## Teardown

To completely uninstall the stack and all its components:

```bash
/opt/homebrew/bin/bash teardown.sh
```

This will:
- Stop and remove all Podman machines
- Kill any stray `gvproxy` and `krunkit` processes
- Uninstall `podman`, `podman-desktop`, `kind`, `helm`, `krunkit`, and `libkrun-efi`
- Remove the `slp/krunkit` brew tap
- Delete all Podman config and data directories

> **Warning:** This is destructive and irreversible. All containers, images, volumes, and cluster data will be permanently deleted. Downloaded models will also be lost.

---

## Day-to-Day Operations

### Starting after a reboot
The Podman machine and kind cluster do not start automatically after a reboot:
```bash
podman machine start podman-machine-default
podman system connection default podman-machine-default-root
kind export kubeconfig --name ai-cluster
kubectl get nodes
```

### Stopping everything
```bash
kubectl delete --all pods -A 2>/dev/null || true
podman machine stop podman-machine-default
```

---

## Using llama.cpp (llama-server)

llama-server exposes an OpenAI-compatible HTTP API on `http://localhost:30480`.

### List available models
```bash
curl -s http://localhost:30480/v1/models | python3 -m json.tool
```

### Chat completions (OpenAI-compatible)
```bash
curl http://localhost:30480/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Mistral-7B-Instruct-v0.3-Q4_K_M",
    "messages": [{"role": "user", "content": "Explain Kubernetes in one paragraph."}]
  }'
```

### Raw completion
```bash
curl http://localhost:30480/completion \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Llama-3.2-3B-Instruct-Q4_K_M",
    "prompt": "The history of computer graphics began",
    "n_predict": 200
  }'
```

### Model names
Use the GGUF filename without the `.gguf` extension as the model name in requests:

| Model | Request name |
|---|---|
| gpt-oss-20b | `openai_gpt-oss-20b-MXFP4` |
| Mistral 7B | `Mistral-7B-Instruct-v0.3-Q4_K_M` |
| Llama 3.2 3B | `Llama-3.2-3B-Instruct-Q4_K_M` |

---

## Managing llama.cpp Models

Models are configured in `helm/llamacpp/values.yaml` under the `models` list. All models are downloaded at install time by the model-loader Job and stored on a PersistentVolume. llama-server loads a model into GPU memory on first request and unloads it when idle.

### Adding or removing models
Edit `helm/llamacpp/values.yaml` and upgrade the Helm release:

```yaml
models:
  - name: "mistral-7b"
    hf_repo: "bartowski/Mistral-7B-Instruct-v0.3-GGUF"
    filename: "Mistral-7B-Instruct-v0.3-Q4_K_M.gguf"
  - name: "llama3.2-3b"
    hf_repo: "bartowski/Llama-3.2-3B-Instruct-GGUF"
    filename: "Llama-3.2-3B-Instruct-Q4_K_M.gguf"
  # Large models — add after initial setup
  # - name: "gpt-oss-20b"
  #   hf_repo: "bartowski/openai_gpt-oss-20b-GGUF"
  #   filename: "openai_gpt-oss-20b-MXFP4.gguf"
```

```bash
helm upgrade llamacpp ./helm/llamacpp -n llamacpp
```

### Downloading a model manually
```bash
kubectl exec -it -n llamacpp deployment/llamacpp -- \
  curl -L -o /models/<filename>.gguf \
  "https://huggingface.co/<hf_repo>/resolve/main/<filename>.gguf"
```

### Listing downloaded models
```bash
kubectl exec -n llamacpp deployment/llamacpp -- ls -lh /models/
```

### Removing a model
```bash
kubectl exec -n llamacpp deployment/llamacpp -- rm /models/<filename>.gguf
```

### GPU tuning
Inference settings are configured in `helm/llamacpp/values.yaml`:
```yaml
server:
  gpuLayers: 999      # layers to offload to GPU (999 = all)
  contextSize: 8192   # context window size
  threads: 8          # CPU threads for non-GPU work
```

---

## Using Ollama

Ollama exposes its API on `http://localhost:30434`.

### List downloaded models
```bash
curl -s http://localhost:30434/api/tags | python3 -m json.tool
```

### Generate a completion
```bash
curl http://localhost:30434/api/generate \
  -H "Content-Type: application/json" \
  -d '{"model": "mistral", "prompt": "Explain Kubernetes.", "stream": false}'
```

---

## Managing Ollama Models

Models are configured in `helm/ollama/values.yaml` under the `models.pull` list:

```yaml
models:
  pull:
    - llama3.2
    - mistral
    # - gpt-oss:20b   # large models — add after initial setup
```

```bash
helm upgrade ollama ./helm/ollama -n ollama
```

### Pulling a model manually
```bash
kubectl exec -it <ollama-pod-name> -n ollama -- ollama pull <model-name>
```

### Pulling from HuggingFace
```bash
kubectl exec -it <ollama-pod-name> -n ollama -- \
  ollama pull hf.co/bartowski/openai_gpt-oss-20b-GGUF:Q4_K_M
```

### Listing and removing models
```bash
kubectl exec -it <ollama-pod-name> -n ollama -- ollama list
kubectl exec -it <ollama-pod-name> -n ollama -- ollama rm <model-name>
```

---

## GPU Performance Benchmarks

Benchmarks run on a **Mac M3 Pro** using Vulkan GPU acceleration via krunkit/libkrun-efi.

### llama.cpp tok/s

```bash
# Replace model name with one of your downloaded models
curl -s http://localhost:30480/completion \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Mistral-7B-Instruct-v0.3-Q4_K_M",
    "prompt": "Write a detailed technical essay about the history of computer graphics, covering rasterization, ray tracing, and modern GPU architectures.",
    "n_predict": 200,
    "stream": false
  }' | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(f'Model:        {d[\"model\"]}')
print(f'Generation:   {d[\"timings\"][\"predicted_per_second\"]:.1f} tok/s  ({d[\"timings\"][\"predicted_n\"]} tokens)')
print(f'Prompt eval:  {d[\"timings\"][\"prompt_per_second\"]:.1f} tok/s  ({d[\"timings\"][\"prompt_n\"]} tokens)')
print(f'Time to first token: {d[\"timings\"][\"prompt_ms\"]:.0f}ms')
"
```

| Model | Size | llama.cpp tok/s | Ollama tok/s | llama.cpp advantage | Native Metal M3 Pro (est.) |
|---|---|---|---|---|---|
| llama3.2 | 3B | ~55.3 tok/s | ~49 tok/s | +13% | ~90–110 tok/s |
| mistral | 7B | ~28.4 tok/s | ~26 tok/s | +9% | ~30–35 tok/s |
| gpt-oss:20b | 20B | ~43.9 tok/s | ~27 tok/s | +63% | ~60–70 tok/s |

> Benchmarks run on an M3 Pro using prompt "Write a story about a robot." llama.cpp outperforms Ollama across all model sizes, with the advantage growing significantly on larger models — gpt-oss:20b is 63% faster under llama.cpp due to lower Vulkan queue overhead and the absence of a Go runtime in the inference path.
>
> **Native Metal figures** are community-sourced estimates for llama.cpp running directly on macOS (`-ngl 99`, all layers GPU-offloaded, no VM). llama3.2 3B is a very small model that easily saturates available bandwidth; mistral 7B (Q4\_K\_M) at ~150 GB/s already runs close to native even through Vulkan; gpt-oss:20b benefits from its MoE architecture (~3.6B active params per token), and community reports of ~60–86 tok/s on M2/M3-class chips confirm headroom above the containerised figures.

### Ollama tok/s

```bash
curl -s http://localhost:30434/api/generate -d '{
  "model": "mistral",
  "prompt": "Write a detailed technical essay about the history of computer graphics.",
  "stream": false
}' | python3 -c "
import json, sys
d = json.load(sys.stdin)
tps = d['eval_count'] / (d['eval_duration'] / 1e9)
print(f'Tokens/sec: {tps:.1f}')
print(f'Tokens generated: {d[\"eval_count\"]}')
print(f'Time: {d[\"eval_duration\"]/1e9:.2f}s')
"
```

---

## Updating the llama.cpp Image

The llama.cpp image is built from source inside the Podman VM with Vulkan patches applied for krunkit/virtio-gpu compatibility.

### 1. Remove the existing image to force a rebuild
```bash
# Remove from kind node
podman machine ssh podman-machine-default -- \
  podman exec ai-cluster-control-plane \
  ctr -n k8s.io images rm localhost/fedora-llamacpp-vulkan:v1 2>/dev/null || true

# Remove from VM
podman machine ssh podman-machine-default -- \
  podman rmi localhost/fedora-llamacpp-vulkan:v1 2>/dev/null || true
```

### 2. Re-run the setup script
```bash
/opt/homebrew/bin/bash setup.sh
```

### 3. Restart the deployment to pick up the new image
```bash
kubectl rollout restart deployment/llamacpp -n llamacpp
kubectl rollout status deployment/llamacpp -n llamacpp
```

### Pinning a specific llama.cpp version
Edit `llama-cpp/macos/Dockerfile` and change the clone line:
```dockerfile
# Replace this:
RUN git clone --depth 1 https://github.com/ggml-org/llama.cpp.git /llama.cpp

# With a specific tag (example):
RUN git clone --branch b5140 --depth 1 https://github.com/ggml-org/llama.cpp.git /llama.cpp
```

---

## Updating the Ollama Image

### 1. Remove the existing image to force a rebuild
```bash
podman machine ssh podman-machine-default -- \
  podman rmi fedora-ollama-vulkan:v1 2>/dev/null || true

podman machine ssh podman-machine-default -- \
  podman exec ai-cluster-control-plane \
  ctr -n k8s.io images rm docker.io/library/fedora-ollama-vulkan:v1 2>/dev/null || true
```

### 2. Re-run the setup script
```bash
/opt/homebrew/bin/bash setup.sh
```

### 3. Restart the deployment
```bash
kubectl rollout restart deployment/ollama -n ollama
kubectl rollout status deployment/ollama -n ollama
```

---

## Updating Helm Charts

```bash
# Upgrade a single release
helm upgrade llamacpp ./helm/llamacpp -n llamacpp
helm upgrade ollama   ./helm/ollama   -n ollama
helm upgrade n8n      ./helm/n8n      -n n8n

# Rollback a release
helm rollback llamacpp -n llamacpp

# Check release history
helm history llamacpp -n llamacpp
```

---

## Recreating the kind Cluster

Required when adding or removing port mappings, or when the cluster becomes unrecoverable:

```bash
export DOCKER_HOST="unix://$(podman info --format '{{.Host.RemoteSocket.Path}}')"
export KIND_EXPERIMENTAL_PROVIDER=podman
kind delete cluster --name ai-cluster
/opt/homebrew/bin/bash setup.sh
```

---

## Recreating the Podman Machine

Required when changing CPU/memory/disk in `config.yaml`, or after a krunkit upgrade:

```bash
podman machine stop podman-machine-default
podman machine rm podman-machine-default
/opt/homebrew/bin/bash setup.sh
```

> **Warning:** This destroys the kind cluster and all loaded images. Downloaded models on PersistentVolumes are preserved if `helm.sh/resource-policy: keep` is set on the PVCs (default).

---

## Troubleshooting

### kubectl cannot reach the cluster after reboot
```bash
podman machine start podman-machine-default
podman system connection default podman-machine-default-root
kind export kubeconfig --name ai-cluster
```

### kind delete/get cluster fails with Docker socket error
```bash
export DOCKER_HOST="unix://$(podman info --format '{{.Host.RemoteSocket.Path}}')"
export KIND_EXPERIMENTAL_PROVIDER=podman
kind get clusters
```

### Podman machine crashes under load
libkrun-efi can crash the VM under heavy CPU or memory pressure. Recovery:
```bash
podman machine stop podman-machine-default 2>/dev/null || true
podman machine start podman-machine-default
podman system connection default podman-machine-default-root
kind export kubeconfig --name ai-cluster
kubectl get nodes
```
If crashes are frequent, reduce `memory` in `config.yaml` and recreate the machine.

### llama-server not responding
```bash
# Check pod status
kubectl get pods -n llamacpp

# Check logs
kubectl logs -n llamacpp deployment/llamacpp -f

# Check Vulkan is working — should show "Virtio-GPU Venus"
kubectl logs -n llamacpp deployment/llamacpp | grep -i vulkan

# Check the model file exists on the PVC
kubectl exec -n llamacpp deployment/llamacpp -- ls -lh /models/
```

### llama-server falls back to CPU (no Vulkan device found)
```bash
# Check Vulkan device enumeration in the pod
kubectl exec -n llamacpp deployment/llamacpp -- test-vulkan

# Verify DRI permissions were set correctly by the init container
kubectl logs -n llamacpp -l app.kubernetes.io/name=llamacpp \
  -c fix-dri-permissions
```

### Model download stuck or failed
```bash
# Check model-loader job logs
kubectl logs -n llamacpp -l app.kubernetes.io/component=model-loader -f

# Check job status
kubectl get jobs -n llamacpp

# Re-trigger download by deleting the job (helm upgrade will recreate it)
kubectl delete job -n llamacpp -l app.kubernetes.io/component=model-loader
helm upgrade llamacpp ./helm/llamacpp -n llamacpp
```

### Ollama not responding
```bash
kubectl get pods -n ollama
kubectl logs -n ollama deployment/ollama -f
kubectl logs -n ollama deployment/ollama | grep -i vulkan
```

### Podman is running rootless
```bash
podman system connection default podman-machine-default-root
podman info --format '{{.Host.Security.Rootless}}'   # must be: false
```

### Check krunkit/VM logs
```bash
log show --predicate 'process == "krunkit"' --last 30m | grep -i error
```