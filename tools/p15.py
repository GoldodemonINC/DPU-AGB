import io
p = 'src/backend/icd/probe.zig'
s = io.open(p, encoding='utf-8').read()
old = '    const h = [_]?*anyopaque{ device, phys, vk };'
assert old in s
# Instance first. This loader's vkGetInstanceProcAddr validates its first
# argument as a VkInstance and aborts the process on a VkDevice or a
# VkPhysicalDevice, so any other handle must only be reached if the instance
# lookup already failed -- which it does not for any command used here.
new = ('    // The instance is tried first and the rest only as a fallback: this\n'
       '    // loader aborts the process when vkGetInstanceProcAddr is handed a\n'
       '    // VkDevice or VkPhysicalDevice rather than returning null, so a\n'
       '    // "helpful" device-first order would kill the probe rather than\n'
       '    // report a missing entry point. Every command here resolves against\n'
       '    // the instance anyway.\n'
       '    const h = [_]?*anyopaque{ vk, device, phys };')
s = s.replace(old, new, 1)
io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('ok')
