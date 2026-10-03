import io
p = 'src/backend/icd/probe.zig'
s = io.open(p, encoding='utf-8').read()
old = '"vkEnumeratePhysicalDeviceQueueFamilyProperties"'
assert old in s
# The 1.0 spelling. The 1.3-promoted alias is not in this loader's export table,
# and a probe that assumes it is present fails for a reason that has nothing to
# do with the driver it is trying to test.
new = '"vkGetPhysicalDeviceQueueFamilyProperties"'
s = s.replace(old, new, 1)
io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('ok')
