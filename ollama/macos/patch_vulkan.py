"""
Patch ggml-vulkan.cpp to remove __APPLE__ guards around VK_KHR_portability_enumeration.

On Linux with krunkit/virtio-gpu (Apple Silicon via Venus driver), Vulkan device
enumeration requires VK_KHR_portability_enumeration - the same extension used on
macOS with MoltenVK. Without this patch, ggml finds zero Vulkan devices on Linux
even though vulkaninfo correctly sees the GPU.
"""

filepath = '/ollama/ml/backend/ggml/ggml/src/ggml-vulkan/ggml-vulkan.cpp'

with open(filepath, 'r') as f:
    content = f.read()

patches = [
    (
        '#ifdef __APPLE__\n    const bool portability_enumeration_ext = ggml_vk_instance_portability_enumeration_ext_available(instance_extensions);\n#endif',
        'const bool portability_enumeration_ext = ggml_vk_instance_portability_enumeration_ext_available(instance_extensions);'
    ),
    (
        '#ifdef __APPLE__\n    if (portability_enumeration_ext) {\n        extensions.push_back("VK_KHR_portability_enumeration");\n    }\n#endif',
        'if (portability_enumeration_ext) {\n        extensions.push_back("VK_KHR_portability_enumeration");\n    }'
    ),
    (
        '#ifdef __APPLE__\n    if (portability_enumeration_ext) {\n        instance_create_info.flags |= vk::InstanceCreateFlagBits::eEnumeratePortabilityKHR;\n    }\n#endif',
        'if (portability_enumeration_ext) {\n        instance_create_info.flags |= vk::InstanceCreateFlagBits::eEnumeratePortabilityKHR;\n    }'
    ),
]

applied = 0
for old, new in patches:
    if old in content:
        content = content.replace(old, new)
        applied += 1
    else:
        print(f'WARNING: patch {applied + 1} pattern not found - source may have changed')

with open(filepath, 'w') as f:
    f.write(content)

print(f'patch_vulkan.py: applied {applied}/{len(patches)} patches')
if applied != len(patches):
    exit(1)