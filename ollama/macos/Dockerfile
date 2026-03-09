# ==============================================================================
# Stage 1: Build Ollama with Vulkan support for Apple Silicon via krunkit/virtio-gpu
# ==============================================================================
FROM quay.io/slopezpa/fedora-vgpu-llama:latest AS builder

USER root

# Install patched Mesa driver (Vulkan-to-Metal via krunkit) + build tools
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

# Install Go
RUN ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') && \
    curl -fsSL https://go.dev/dl/go1.26.0.linux-${ARCH}.tar.gz -o /tmp/go.tar.gz && \
    tar -C /usr/local -xzf /tmp/go.tar.gz && \
    rm /tmp/go.tar.gz

# Go environment
ENV PATH="/usr/local/go/bin:$PATH"
ENV GOTOOLCHAIN=local
ENV GOGC=off
ENV GOAMD64=v1
ENV CGO_ENABLED=1

# Set GOARCH from build arg (important for aarch64 to avoid CGO passing -m64)
ARG TARGETARCH
ENV GOARCH=${TARGETARCH:-amd64}

# Clone Ollama
RUN git clone https://github.com/ollama/ollama.git /ollama
WORKDIR /ollama

# Patch 1: Remove __APPLE__ guards around VK_KHR_portability_enumeration so
# Venus/virtio-gpu devices are enumerated on Linux (needed for krunkit on Apple Silicon)
# Patching enumerator to work with APPLE running in LINUX container
COPY patch_vulkan.py /tmp/patch_vulkan.py
RUN python3 /tmp/patch_vulkan.py

# Patch 2: Remove duplicate ggml-vulkan add_subdirectory from top-level CMakeLists.txt
# (it's already included via ml/backend/ggml/ggml/src/CMakeLists.txt)
COPY patch_cmake.py /tmp/patch_cmake.py
RUN python3 /tmp/patch_cmake.py

# Build C++ backends (ggml-base, ggml-cpu, ggml-vulkan) via cmake
RUN mkdir -p /build && \
    cd /build && \
    cmake /ollama \
        -DGGML_VULKAN=ON \
        -DGGML_OPENMP=OFF \
        -DCMAKE_BUILD_TYPE=Release && \
    cmake --build . --parallel $(nproc)

# Fix RUNPATH in built libs so they find each other in /usr/lib64 at runtime
RUN patchelf --set-rpath /usr/lib64 /build/lib/ollama/libggml-vulkan.so && \
    patchelf --set-rpath /usr/lib64 /build/lib/ollama/libggml-cpu.so && \
    patchelf --set-rpath /usr/lib64 /build/lib/ollama/libggml-base.so

# Build the Ollama binary (links against ggml libs via cgo)
ENV OLLAMA_LIBRARY_PATH=/usr/lib64
ENV LD_LIBRARY_PATH=/usr/lib64
RUN go build -o /usr/lib64/ollama .

# ==============================================================================
# Stage 2: Runtime image
# ==============================================================================
FROM quay.io/slopezpa/fedora-vgpu-llama:latest AS runtime

USER root

# Install runtime utilities
RUN yum install -y bc jq patchelf && \
    yum clean all

# --- Override base image ggml libs with freshly patched builds ---
# The base image has older libs from July 2025. We replace them with our
# patched builds that include the Vulkan portability fix for krunkit/Venus.
COPY --from=builder /build/lib/ollama/libggml-base.so.0.0.0 /usr/lib64/libggml-base.so.0.0.0
COPY --from=builder /build/lib/ollama/libggml-cpu.so        /usr/lib64/libggml-cpu.so
COPY --from=builder /build/lib/ollama/libggml-vulkan.so     /usr/lib64/libggml-vulkan.so

# Re-create symlinks for libggml-base (versioned symlink chain)
RUN ln -sf libggml-base.so.0.0.0 /usr/lib64/libggml-base.so.0 && \
    ln -sf libggml-base.so.0      /usr/lib64/libggml-base.so

# Fix RPATHs so libs find each other in /usr/lib64
RUN patchelf --set-rpath /usr/lib64 /usr/lib64/libggml-vulkan.so && \
    patchelf --set-rpath /usr/lib64 /usr/lib64/libggml-cpu.so && \
    patchelf --set-rpath /usr/lib64 /usr/lib64/libggml-base.so.0.0.0

# --- The Ollama binary (71MB, self-contained, embeds the runner) ---
COPY --from=builder /usr/lib64/ollama /usr/lib64/ollama
RUN patchelf --set-rpath /usr/lib64 /usr/lib64/ollama && \
    ln -sf /usr/lib64/ollama /usr/local/bin/ollama

# Verify the binary can find all its deps
RUN echo "=== ollama binary deps ===" && \
    ldd /usr/lib64/ollama | grep -E "(ggml|vulkan|not found)" && \
    echo "=== ggml-vulkan deps ===" && \
    ldd /usr/lib64/libggml-vulkan.so | grep "not found" || true

# Tell Ollama where to find its libs
ENV OLLAMA_LIBRARY_PATH=/usr/lib64
ENV LD_LIBRARY_PATH=/usr/lib64
ENV OLLAMA_VULKAN=true
ENV GGML_VK_VISIBLE_DEVICES=0

# Flash attention must be OFF — Venus/virtio-gpu does not support it
ENV OLLAMA_FLASH_ATTENTION=0
ENV GGML_VULKAN_DISABLE_ASYNC_COMPUTE=1
ENV GGML_VULKAN_NO_ASYNC_COMPUTE=1

# Fix render and video GIDs to match host/krunkit device GIDs
RUN groupmod -g 226 render && \
    groupmod -g 44  video  && \
    usermod -aG render,video root

EXPOSE 11434
ENTRYPOINT ["ollama"]
CMD ["serve"]