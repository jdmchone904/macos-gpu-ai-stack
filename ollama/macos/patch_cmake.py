with open('/ollama/CMakeLists.txt', 'r') as f:
    content = f.read()

import re
# Match the full NOT APPLE block including both endifs
pattern = r'if\(NOT APPLE\).*?endif\(\)\s*endif\(\)[^\n]*\n'
match = re.search(pattern, content, re.DOTALL)
if match:
    print('Found block:')
    print(repr(match.group()))
    content = content[:match.start()] + '# ggml-vulkan handled by ggml src CMakeLists\n' + content[match.end():]
    print('Patch applied successfully')
else:
    print('Block not found, showing file around line 160-180:')
    for i, line in enumerate(content.split('\n')[155:185], start=156):
        print(f'{i}: {line}')

with open('/ollama/CMakeLists.txt', 'w') as f:
    f.write(content)