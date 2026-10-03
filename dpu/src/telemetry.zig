//! Real telemetry sampling: live process inventory plus the P:\ capacity pool.
//!
//! Everything reported here is measured. Nothing is simulated, because a
//! dashboard that draws pretty invented numbers is worse than no dashboard at
//! all — it hides whether the engine underneath is actually doing its job.
const std = @import("std");
const win = @import("win");
const c = win.c;

pub const Role = enum {
    /// AI runtime — the things that would hold VRAM-resident weights.
    agent,
    /// Compositor / capture / graphics pipelines competing for the same RAM.
    graphics,
    /// Everything else on the box.
    system,

    pub fn label(self: Role) []const u8 {
        return switch (self) {
            .agent => "AGENT",
            .graphics => "GFX",
            .system => "SYS",
        };
    }
};

/// A single tracked process. `cpu_pct` is computed between consecutive samples
/// by the sampler, so ProcessEntry itself stays a pure snapshot of the OS.
pub const Proc = struct {
    pid: u32,
    name: [64]u8,
    name_len: u8,
    working_set: u64,
    private_bytes: u64,
    page_faults: u32,
    /// 100ns units of kernel+user CPU, for delta-based CPU accounting.
    cpu_time: u64,
    role: Role,
    /// True when this PID was present in the previous sample, so the UI can
    /// tell "still resident" apart from "just spawned".
    returning: bool = false,

    pub fn displayName(self: *const Proc, buf: []u8) []const u8 {
        return buf[0..@min(self.name_len, buf.len)];
    }
};

/// Prior CPU-time snapshot keyed by PID, for turning cumulative CPU time into
/// an interval percentage.
const CpuSnapshot = struct {
    pid: u32,
    cpu_time: u64,
};

pub const Sampler = struct {
    allocator: std.mem.Allocator,
    pool_path: [:0]const u16,
    pool_bytes: u64,

    procs: std.array_list.Managed(Proc),
    previous: std.array_list.Managed(CpuSnapshot),
    /// Parallel to `procs`; holds CPU% computed during the current sample.
    cpu_pct: std.array_list.Managed(f64),

    pub fn init(allocator: std.mem.Allocator, pool_path: [:0]const u16) Sampler {
        return .{
            .allocator = allocator,
            .pool_path = pool_path,
            .pool_bytes = 0,
            .procs = std.array_list.Managed(Proc).init(allocator),
            .previous = std.array_list.Managed(CpuSnapshot).init(allocator),
            .cpu_pct = std.array_list.Managed(f64).init(allocator),
        };
    }

    pub fn deinit(self: *Sampler) void {
        self.procs.deinit();
        self.previous.deinit();
        self.cpu_pct.deinit();
    }

    /// Walk the process snapshot and rebuild the tracked list.
    ///
    /// Processes that vanish between snapshots are simply absent next frame; a
    /// handle is opened and closed per process rather than cached, because a
    /// cached handle to a dead PID is a use-after-exit waiting to happen and
    /// this runs every 250 ms.
    pub fn refresh(self: *Sampler) void {
        self.previous.clearRetainingCapacity();
        for (self.procs.items) |p| {
            self.previous.append(.{ .pid = p.pid, .cpu_time = p.cpu_time }) catch {};
        }

        self.procs.clearRetainingCapacity();
        self.cpu_pct.clearRetainingCapacity();

        const snap = c.CreateToolhelp32Snapshot(c.TH32CS_SNAPPROCESS, 0);
        if (snap == c.INVALID_HANDLE_VALUE) return;
        defer _ = c.CloseHandle(snap);

        var entry: c.PROCESSENTRY32W = undefined;
        entry.dwSize = @sizeOf(c.PROCESSENTRY32W);
        if (c.Process32FirstW(snap, &entry) == 0) return;

        while (true) {
            try self.appendEntry(&entry);

            entry.dwSize = @sizeOf(c.PROCESSENTRY32W);
            if (c.Process32NextW(snap, &entry) == 0) break;
        }

        // The dashboard shows a fixed number of node slots, so the heaviest
        // residents must land in them. `cpu_pct` is index-parallel but is still
        // all zeroes at this point and gets filled after this sort.
        std.mem.sort(Proc, self.procs.items, {}, struct {
            fn lessThan(_: void, a: Proc, b: Proc) bool {
                return a.working_set > b.working_set;
            }
        }.lessThan);
    }

    fn appendEntry(self: *Sampler, entry: *const c.PROCESSENTRY32W) !void {
        // Skipping the idle/PID-0 entry avoids an OpenProcess that always fails.
        if (entry.th32ProcessID == 0) return;

        const handle = c.OpenProcess(
            c.PROCESS_QUERY_LIMITED_INFORMATION | c.PROCESS_VM_READ,
            0,
            entry.th32ProcessID,
        );
        if (handle == null) return;
        defer _ = c.CloseHandle(handle);

        // The _EX variant is required: plain PROCESS_MEMORY_COUNTERS has no
        // PrivateUsage field, and PagefileUsage is not the same quantity.
        // _EX is documented as a superset sharing the base struct's layout, so
        // the pointer cast is well-defined.
        var mem: c.PROCESS_MEMORY_COUNTERS_EX = undefined;
        mem.cb = @sizeOf(c.PROCESS_MEMORY_COUNTERS_EX);
        const counters: c.PPROCESS_MEMORY_COUNTERS = @ptrCast(&mem);
        if (c.GetProcessMemoryInfo(handle, counters, @intCast(@sizeOf(c.PROCESS_MEMORY_COUNTERS_EX))) == 0) return;

        // Idle (0) and System (4) are not meaningful workload nodes.
        if (entry.szExeFile[0] == 0) return;

        var proc: Proc = .{
            .pid = entry.th32ProcessID,
            .name = undefined,
            .name_len = 0,
            .working_set = mem.WorkingSetSize,
            .private_bytes = mem.PrivateUsage,
            .page_faults = mem.PageFaultCount,
            .cpu_time = 0,
            .role = .system,
        };

        var src: usize = 0;
        while (src < entry.szExeFile.len and entry.szExeFile[src] != 0 and src < proc.name.len) : (src += 1) {
            // szExeFile is UTF-16; these names are ASCII in practice, and
            // truncating a long name is preferable to emitting malformed UTF-8.
            proc.name[src] = @intCast(@as(u16, entry.szExeFile[src]) & 0x7f);
        }
        proc.name_len = @intCast(src);
        proc.role = classify(proc.name[0..proc.name_len]);

        var ft: c.FILETIME = undefined;
        var ext: c.FILETIME = undefined;
        var kt: c.FILETIME = undefined;
        var ct: c.FILETIME = undefined;
        if (c.GetProcessTimes(handle, &ft, &ext, &kt, &ct) != 0) {
            const toU64 = struct {
                fn f(v: c.FILETIME) u64 {
                    return @as(u64, v.dwHighDateTime) << 32 | @as(u64, v.dwLowDateTime);
                }
            }.f;
            // Kernel + user. `ext` is the exit time, which is zero for anything
            // still running and is not part of the CPU accounting at all.
            proc.cpu_time = toU64(kt) + toU64(ct);
            proc.returning = self.wasSeen(entry.th32ProcessID, proc.cpu_time);
        }

        self.procs.append(proc) catch return;
        self.cpu_pct.append(0) catch return;
    }

    /// CPU% over the sample interval, derived from the prior frame's CPU time.
    ///
    /// Called by the server after `refresh`; the true interval is passed in
    /// because the caller owns the cadence.
    pub fn computeCpuPercent(self: *Sampler, interval_ms: u64) void {
        for (self.procs.items, 0..) |p, i| {
            for (self.previous.items) |prev| {
                if (prev.pid != p.pid) continue;
                if (p.cpu_time <= prev.cpu_time) break;
                const delta_hundredths = p.cpu_time - prev.cpu_time; // 100ns units
                const delta_ms = delta_hundredths / 10_000;
                if (delta_ms == 0) break;
                const pct = @as(f64, @floatFromInt(delta_ms)) /
                    @as(f64, @floatFromInt(@max(interval_ms, 1))) * 100.0;
                self.cpu_pct.items[i] = @min(pct, 400.0);
                break;
            }
        }
    }

    fn wasSeen(self: *const Sampler, pid: u32, cpu_time: u64) bool {
        for (self.previous.items) |prev| {
            if (prev.pid == pid) return prev.cpu_time == cpu_time;
        }
        return false;
    }

    pub fn cpuFor(self: *const Sampler, index: usize) f64 {
        if (index >= self.cpu_pct.items.len) return 0;
        return self.cpu_pct.items[index];
    }

    /// Total resident working set across every tracked process.
    pub fn totalWorkingSet(self: *const Sampler) u64 {
        var total: u64 = 0;
        for (self.procs.items) |p| total += p.working_set;
        return total;
    }

    pub fn roleCount(self: *const Sampler, role: Role) usize {
        var n: usize = 0;
        for (self.procs.items) |p| {
            if (p.role == role) n += 1;
        }
        return n;
    }

    pub fn poolSpace(self: *const Sampler) ?win.VolumeSpace {
        return win.VolumeSpace.query(self.pool_path);
    }
};

/// Classify a process by executable name.
///
/// The agent list is intentionally narrow and explicit. A broad heuristic would
/// tag unrelated processes as AI workloads and quietly corrupt the meaning of
/// every panel that depends on the classification.
fn classify(name: []const u8) Role {
    const trimmed = stripExe(name);

    const agent_names = [_][]const u8{
        "ollama",     "ollama_llama_server", "llama-server", "llama-cli",
        "ollama_llama", "wsl-host",          "llama",        "koboldcpp",
    };
    const gfx_names = [_][]const u8{
        "lossless scaling", "losslessscaling", "gamebar", "obs64",
        "steam",            "dwm",             "explorer", "chrome",
        "msedge",           "firefox",
    };

    for (agent_names) |candidate| {
        if (std.ascii.eqlIgnoreCase(trimmed, candidate)) return .agent;
    }
    for (gfx_names) |candidate| {
        if (std.ascii.eqlIgnoreCase(trimmed, candidate)) return .graphics;
    }
    return .system;
}

/// Drop a trailing `.exe` so the classification lists can stay extension-free.
fn stripExe(name: []const u8) []const u8 {
    if (name.len > 4 and std.ascii.eqlIgnoreCase(name[name.len - 4 ..], ".exe")) {
        return name[0 .. name.len - 4];
    }
    return name;
}