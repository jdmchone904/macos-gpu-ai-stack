# ==============================================================================
# Stage 1: Build llama-server with Vulkan support for Apple Silicon via krunkit/virtio-gpu
#
# GPU path: llama-server → Vulkan → virtio-gpu → krunkit → Metal
#
# Build context: ./llamacpp/macos/
# Required files in context:
#   - Dockerfile          (this file)
#   - llama_tps_test.sh   (token/sec test script)
# ==============================================================================
FROM quay.io/slopezpa/fedora-vgpu-llama:latest AS builder

USER root

# Install patched Mesa driver (Vulkan-to-Metal via krunkit) + build tools.
# The COPR mesa-krunkit repo is essential — the stock Mesa Vulkan driver does
# not enumerate Venus/virtio-gpu devices on Linux. Without this downgrade,
# llama-server sees no Vulkan devices and silently falls back to CPU.
# Mirrors the Ollama Dockerfile exactly.
RUN dnf -y install \
        dnf-plugins-core \
        mesa-vulkan-drivers \
        vulkan-loader-devel \
        vulkan-headers \
        vulkan-tools \
        vulkan-loader \
        git cmake gcc gcc-c++ make patchelf && \
    dnf -y copr enable slp/mesa-krunkit epel-9-aarch64 && \
    dnf -y downgrade mesa-vulkan-drivers.aarch64 \
           --repo=copr:copr.fedorainfracloud.org:slp:mesa-krunkit && \
    dnf clean all

# Clone and build llama.cpp with Vulkan backend.
# -DGGML_OPENMP=OFF matches the Ollama build — OpenMP causes hangs under
# virtio-gpu because the Vulkan queue and OpenMP thread pool contend.
RUN git clone --depth 1 https://github.com/ggml-org/llama.cpp.git /llama.cpp

WORKDIR /llama.cpp

RUN cmake -B build \
        -DGGML_VULKAN=ON \
        -DGGML_OPENMP=OFF \
        -DCMAKE_BUILD_TYPE=Release && \
    cmake --build build --config Release -j"$(nproc)"

# Show exactly what was built and where so future path issues are easy to diagnose
RUN echo "=== build/bin ===" && find build/bin -type f -executable && \
    echo "=== ggml libs ===" && find build -name "libggml*" -o -name "libllama*" | sort

# Fix RPATHs on whatever libs were produced — paths vary by llama.cpp version
RUN find build -name "libggml*.so*" -o -name "libllama*.so*" | \
    xargs -I{} patchelf --set-rpath /usr/lib64 {} 2>/dev/null || true

# Fail fast — verify the binary works before committing to the runtime stage
RUN build/bin/llama-server --version

# ==============================================================================
# Stage 2: Runtime image
# ==============================================================================
FROM quay.io/slopezpa/fedora-vgpu-llama:latest AS runtime

USER root

# Runtime utilities — bc/jq for the tps test script, patchelf to fix RPATHs
# after COPY (same requirement as Ollama runtime stage).
# Switched from yum to dnf (yum is a deprecated wrapper on modern Fedora).
RUN dnf install -y bc jq patchelf && dnf clean all

# Copy llama-server binary and associated ggml shared libs.
# We use find+xargs rather than a fixed path because lib location varies
# across llama.cpp versions (build/, build/src/, build/ggml/src/, etc.)
COPY --from=builder /llama.cpp/build/bin/llama-server  /usr/local/bin/llama-server
COPY --from=builder /llama.cpp/build/bin/llama-cli     /usr/local/bin/llama-cli
COPY --from=builder /llama.cpp/build/bin/llama-bench   /usr/local/bin/llama-bench

# Copy all shared libs produced by the build — use find across the entire
# build tree so new libs added in future llama.cpp versions are caught
# automatically without needing to update this Dockerfile.
RUN --mount=type=bind,from=builder,source=/llama.cpp/build,target=/build \
    find /build -name "*.so" -o -name "*.so.*" | \
    xargs -I{} cp -P {} /usr/lib64/ 2>/dev/null || true

# Fix RPATHs on all copied libs so they find each other in /usr/lib64
RUN find /usr/lib64 -maxdepth 1 -name "*.so" -o -name "*.so.*" | \
    xargs -I{} patchelf --set-rpath /usr/lib64 {} 2>/dev/null || true

# Align render/video GIDs to match the host/krunkit device GIDs.
# Copied directly from Ollama Dockerfile — without this, the DRI device
# open() call is rejected by the kernel even with privileged: true.
RUN groupmod -g 226 render && \
    groupmod -g 44  video  && \
    usermod -aG render,video root

# Vulkan diagnostic helper
RUN cat > /usr/local/bin/test-vulkan << 'EOF'
#!/bin/bash
echo "=== Vulkan device check ==="
vulkaninfo --summary 2>/dev/null | head -20 || echo "vulkaninfo unavailable"
echo "=== DRI devices ==="
ls -la /dev/dri/ 2>/dev/null || echo "no /dev/dri"
echo "=== llama-server version ==="
/usr/local/bin/llama-server --version
echo "=== lib deps ==="
ldd /usr/local/bin/llama-server | grep -E "(ggml|vulkan|not found)"
EOF
RUN chmod +x /usr/local/bin/test-vulkan

# Verify the runtime binary resolves all its deps before the image is finalised
RUN echo "=== llama-server deps ===" && \
    ldd /usr/local/bin/llama-server | grep -E "(ggml|vulkan|not found)" && \
    echo "=== ggml-vulkan deps ===" && \
    ldd /usr/lib64/libggml-vulkan.so 2>/dev/null | grep "not found" || true

# Environment — ggml/llama.cpp native variables only.
# OLLAMA_* vars are not applicable here and have no effect on llama-server.

# Ensure shared libs are found at runtime (belt-and-suspenders alongside RPATH)
ENV LD_LIBRARY_PATH=/usr/lib64

# Select the first Vulkan device (the virtio-gpu exposed by krunkit)
ENV GGML_VK_VISIBLE_DEVICES=0
ENV GGML_VK_DEVICE=0

# Flash attention off — Venus/virtio-gpu does not support it; leaving it on
# causes a hard crash at model load time.
ENV GGML_VULKAN_DISABLE_ASYNC_COMPUTE=1
ENV GGML_VULKAN_NO_ASYNC_COMPUTE=1

# Models are mounted from the PersistentVolume at runtime via the Helm chart
RUN mkdir -p /models
WORKDIR /app

EXPOSE 8080
ENTRYPOINT ["llama-server"]
CMD ["--help"]