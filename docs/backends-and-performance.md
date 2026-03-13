# Backends & Performance

## Table of Contents

- [Choosing a backend](#choosing-a-backend)
- [Switching backends](#switching-backends)
- [Performance expectations](#performance-expectations)
- [Benchmarks](#benchmarks)
- [Using llama.cpp](#using-llamacpp)
- [Managing llama.cpp models](#managing-llamacpp-models)
- [Using Ollama](#using-ollama)
- [Managing Ollama models](#managing-ollama-models)

---

## Choosing a backend

**Use llama.cpp** (`llama-server`) for best performance. It has a lower overhead path to the GPU and consistently outperforms Ollama in this stack, especially on larger models.

**Use Ollama** if you need its specific model management features (`ollama pull`, Modelfile customisation) or are integrating with tools that target the Ollama API specifically.

---

## Switching backends

You can switch backends at any time without tearing down the full stack:

```bash
./gpustack backend switch ollama
./gpustack backend switch llamacpp
```

The switch performs a surgical swap:
1. Helm uninstalls the current backend
2. Deletes the backend's PersistentVolumeClaims (model cache)
3. Checks if the target backend image is loaded in kind — builds and loads it if not
4. Helm installs the new backend and downloads models
5. Waits for the deployment to be fully healthy before returning

> **Note:** The first switch to a backend whose image has not been built will trigger a full image build inside the Podman VM, which takes 10–20 minutes.

---

## Performance expectations

Due to the GPU passthrough path (Vulkan → virtio-gpu → krunkit → Metal), you can expect roughly **60–70%+ of native Metal performance**. llama.cpp consistently outperforms Ollama in this stack, with the gap widening on larger models.

---

## Benchmarks

Benchmarks run on an **M3 Pro** using prompt `"Write a story about a robot."` with 200 predicted tokens.

| Model | Size | llama.cpp tok/s | Ollama tok/s | llama.cpp advantage | Native Metal M3 Pro (est.) |
|---|---|---|---|---|---|
| llama3.2 | 3B | ~55.3 tok/s | ~49 tok/s | +13% | ~90–110 tok/s |
| mistral | 7B | ~28.4 tok/s | ~26 tok/s | +9% | ~30–35 tok/s |
| gpt-oss:20b | 20B | ~43.9 tok/s | ~27 tok/s | +63% | ~60–70 tok/s |

> llama.cpp's advantage grows significantly on larger models — gpt-oss:20b is 63% faster due to lower Vulkan queue overhead and the absence of a Go runtime in the inference path.
>
> **Native Metal figures** are community-sourced estimates for llama.cpp running directly on macOS (`-ngl 99`, no VM). llama3.2 3B easily saturates available bandwidth; mistral 7B (Q4\_K\_M) runs close to native even through Vulkan; gpt-oss:20b benefits from its MoE architecture (~3.6B active params per token).

### Run your own benchmarks

**llama.cpp:**
```bash
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
print(f'Model:               {d[\"model\"]}')
print(f'Generation:          {d[\"timings\"][\"predicted_per_second\"]:.1f} tok/s  ({d[\"timings\"][\"predicted_n\"]} tokens)')
print(f'Prompt eval:         {d[\"timings\"][\"prompt_per_second\"]:.1f} tok/s  ({d[\"timings\"][\"prompt_n\"]} tokens)')
print(f'Time to first token: {d[\"timings\"][\"prompt_ms\"]:.0f}ms')
"
```

**Ollama:**
```bash
curl -s http://localhost:30434/api/generate -d '{
  "model": "mistral",
  "prompt": "Write a detailed technical essay about the history of computer graphics.",
  "stream": false
}' | python3 -c "
import json, sys
d = json.load(sys.stdin)
tps = d['eval_count'] / (d['eval_duration'] / 1e9)
print(f'Tokens/sec:       {tps:.1f}')
print(f'Tokens generated: {d[\"eval_count\"]}')
print(f'Time:             {d[\"eval_duration\"]/1e9:.2f}s')
"
```

---

## Using llama.cpp

llama-server exposes an OpenAI-compatible HTTP API on `http://localhost:30480`.

### Health check
```bash
curl http://localhost:30480/health
```

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

## Managing llama.cpp models

Models are configured in `helm/llamacpp/values.yaml` and downloaded at install time by the model-loader Job. They are stored on a PersistentVolume and loaded into GPU memory on first request.

### Adding or removing models

Edit `helm/llamacpp/values.yaml` and upgrade the release:

```yaml
models:
  - name: "mistral-7b"
    hf_repo: "bartowski/Mistral-7B-Instruct-v0.3-GGUF"
    filename: "Mistral-7B-Instruct-v0.3-Q4_K_M.gguf"
  - name: "llama3.2-3b"
    hf_repo: "bartowski/Llama-3.2-3B-Instruct-GGUF"
    filename: "Llama-3.2-3B-Instruct-Q4_K_M.gguf"
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

### Listing and removing models
```bash
kubectl exec -n llamacpp deployment/llamacpp -- ls -lh /models/
kubectl exec -n llamacpp deployment/llamacpp -- rm /models/<filename>.gguf
```

### GPU tuning

```yaml
# helm/llamacpp/values.yaml
server:
  gpuLayers: 999      # layers to offload to GPU (999 = all)
  contextSize: 8192   # context window size
  threads: 8          # CPU threads for non-GPU work
```

---

## Using Ollama

Ollama exposes its API on `http://localhost:30434`.

### Health check
```bash
curl http://localhost:30434/
# returns: Ollama is running
```

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

## Managing Ollama models

Models are configured in `helm/ollama/values.yaml`:

```yaml
models:
  pull:
    - llama3.2
    - mistral
    # - gpt-oss:20b
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