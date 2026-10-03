import io
p = 'src/backend/icd/icd.zig'
s = io.open(p, encoding='utf-8').read()

old_inst = '''const Instance = struct {
    sentinel: u32 = 0x44505501, // "DPU"
};'''
assert old_inst in s, 'Instance'
new_inst = '''/// `VK_LOADER_DATA`. Every dispatchable handle a driver returns -- instance,
/// physical device, device, queue -- must begin with a pointer-sized field
/// holding this value, because the loader reads the first word of each handle
/// to find its own dispatch table.
///
/// A driver that puts a small integer first instead gets its handles rejected:
/// `vkGetDeviceQueue` returns null and the application reports "no queue",
/// which is nowhere near the real fault. This cost a debugging session and is
/// worth writing down.
const VK_LOADER_DATA: usize = 0x01C0DEEE;

const Instance = struct {
    loader_data: *anyopaque = @ptrFromInt(VK_LOADER_DATA),
    sentinel: u32 = 0x44505501, // "DPU"
};'''
s = s.replace(old_inst, new_inst, 1)

old_pd = '''const PhysicalDevice = struct {
    sentinel: u32 = 0x44505502,'''
assert old_pd in s, 'PhysicalDevice'
s = s.replace(old_pd, '''const PhysicalDevice = struct {
    loader_data: *anyopaque = @ptrFromInt(VK_LOADER_DATA),
    sentinel: u32 = 0x44505502,''', 1)

old_q = '''const Queue = struct {
    sentinel: u32 = 0x44505504,'''
assert old_q in s, 'Queue'
s = s.replace(old_q, '''const Queue = struct {
    loader_data: *anyopaque = @ptrFromInt(VK_LOADER_DATA),
    sentinel: u32 = 0x44505504,''', 1)

old_d = '''const Device = struct {
    sentinel: u32 = 0x44505503,'''
assert old_d in s, 'Device'
s = s.replace(old_d, '''const Device = struct {
    loader_data: *anyopaque = @ptrFromInt(VK_LOADER_DATA),
    sentinel: u32 = 0x44505503,''', 1)

io.open(p, 'w', encoding='utf-8', newline='').write(s)
print('dispatchable handles fixed')
