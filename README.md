# macos-gpu-ai-stack
### Kubernetes on Podman with GPU-accelerated llama.cpp and n8n

This stack runs a local Kubernetes cluster on macOS using Podman with GPU passthrough via krunkit/libkrun-efi, giving llama.cpp and Ollama access to the host's Metal GPU instead of falling back to CPU inference.

---

## Table of Contents

- [Why run in Kubernetes?](#why-run-in-kubernetes)
- [Components](#components)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [CLI Reference](#cli-reference)
- [Post-Installation](#post-installation)
- [Docs](#docs)

---

## Why run in Kubernetes?

Running llama.cpp natively on macOS via Metal will always be faster. However, the goal of this stack is not raw performance — it's to provide a **reliable, isolated, and extensible local AI platform** that you can build on top of.

By running inside Kubernetes you get:
- **Isolation** — models and services run in containers with defined resource limits, keeping your Mac environment clean
- **Extensibility** — easily add services alongside llama.cpp such as n8n for workflow automation, Open WebUI for a chat interface, custom model training pipelines, or any other containerized workload
- **Reproducibility** — the entire stack is defined as code and can be spun up from scratch on any Apple Silicon Mac with a single command
- **Service networking** — all services communicate via Kubernetes DNS, making it easy to wire up complex multi-service AI workflows

---

## Components

| Component | Role |
|---|---|
| **Podman** | Container engine (replaces Docker) |
| **krunkit + libkrun-efi** | Hypervisor that enables GPU passthrough from macOS to the VM |
| **kind** | Kubernetes cluster running inside the Podman VM |
| **llama.cpp** | High-performance LLM inference server with Vulkan/GPU acceleration (recommended) |
| **Ollama** | Alternative LLM inference server with Vulkan/GPU acceleration |
| **n8n** | Workflow automation platform |

---

## Prerequisites

**Hardware**
- Apple Silicon Mac (M1 or later)
- macOS Sequoia 15.0 or later
- 16GB RAM minimum (24GB+ recommended)

**Software**

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
Adjust resources to match your machine:

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
      - containerPort: 80
        hostPort: 8080
        protocol: TCP
      - containerPort: 443
        hostPort: 8443
        protocol: TCP
```

### 4. Review helm/llamacpp/values.yaml

Configure which models to download and serve:

```yaml
models:
  - name: "mistral-7b"
    hf_repo: "bartowski/Mistral-7B-Instruct-v0.3-GGUF"
    filename: "Mistral-7B-Instruct-v0.3-Q4_K_M.gguf"
  - name: "llama3.2-3b"
    hf_repo: "bartowski/Llama-3.2-3B-Instruct-GGUF"
    filename: "Llama-3.2-3B-Instruct-Q4_K_M.gguf"
  # Large models — add after initial setup via helm upgrade
  # - name: "gpt-oss-20b"
  #   hf_repo: "bartowski/openai_gpt-oss-20b-GGUF"
  #   filename: "openai_gpt-oss-20b-MXFP4.gguf"
```

> **Recommendation:** Comment out large models (20B+) during initial setup and add them afterwards via `helm upgrade` to avoid long waits.

### 5. Run setup

```bash
./gpustack setup
```

The setup will prompt you to choose a backend:
```
  Which inference backend would you like to install?
  1) llama.cpp  [default]
  2) Ollama

  Enter choice [1]:
```

It will then install all tools, create the Podman VM, build the backend image, create the kind cluster, and install all Helm charts. **The first run takes 20–40 minutes** depending on your internet connection and chosen models. Subsequent runs skip already-completed steps.

#### Optional: install gpustack to your PATH

If you'd prefer to run `gpustack` from anywhere instead of `./gpustack` from the repo root:

```bash
make install    # symlinks ./gpustack → /usr/local/bin/gpustack
make uninstall  # removes the symlink
make check      # verify install and print version
```

---

## CLI Reference

```
./gpustack <command> [subcommand] [options]
```

| Command | Description |
|---|---|
| `./gpustack setup` | Install and configure the full GPU stack |
| `./gpustack teardown [--force]` | Destroy the full GPU stack |
| `./gpustack cluster <subcommand>` | Manage the Podman machine and kind cluster |
| `./gpustack backend <subcommand>` | Manage inference backends |
| `./gpustack --help` | Show help |
| `./gpustack --version` | Show version |

Run `./gpustack <command> --help` for detailed help on any command.

**cluster subcommands**

| Subcommand | Description |
|---|---|
| `./gpustack cluster start` | Start Podman machine and kind cluster |
| `./gpustack cluster stop` | Stop kind cluster and Podman machine |
| `./gpustack cluster status` | Show node, pod, Helm release, and backend health |

**backend subcommands**

| Subcommand | Description |
|---|---|
| `./gpustack backend status` | Show health, pod status, and recent logs |
| `./gpustack backend start` | Scale the active backend deployment up |
| `./gpustack backend stop` | Scale the active backend deployment down |
| `./gpustack backend logs` | Tail logs for the active backend pod |
| `./gpustack backend switch <llamacpp\|ollama>` | Switch active backend |

---

## Post-Installation

### Set environment variables permanently

```bash
# zsh (default on macOS)
echo 'export KIND_EXPERIMENTAL_PROVIDER=podman' >> ~/.zshrc
echo 'export DOCKER_HOST="unix://$(podman info --format '\''{{.Host.RemoteSocket.Path}}'\'' 2>/dev/null)"' >> ~/.zshrc
source ~/.zshrc
```

```bash
# bash
echo 'export KIND_EXPERIMENTAL_PROVIDER=podman' >> ~/.bash_profile
echo 'export DOCKER_HOST="unix://$(podman info --format '\''{{.Host.RemoteSocket.Path}}'\'' 2>/dev/null)"' >> ~/.bash_profile
source ~/.bash_profile
```

### Verify the installation

```bash
podman info --format '{{.Host.Security.Rootless}}'  # must be: false
kubectl get nodes
kubectl get pods -A
helm list -A
```

### Verify endpoints

```bash
curl http://localhost:30480/health   # llama.cpp
curl http://localhost:30434/         # Ollama — returns "Ollama is running"
open http://localhost:30678          # n8n
```

---

## Docs

- [Backends & Performance](docs/backends-and-performance.md) — llama.cpp vs Ollama, API usage, model management, benchmarks
- [Operations](docs/operations.md) — starting/stopping, updating images, upgrading Helm charts, recreating the cluster or machine
- [Troubleshooting](docs/troubleshooting.md) — diagnostic commands, error recovery, Vulkan issues, model download failures