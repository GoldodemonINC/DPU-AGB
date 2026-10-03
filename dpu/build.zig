const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ----------------------------------------------------------- shared modules
    //
    // `win` and `tiers` are shared, not duplicated, and that is a correctness
    // property rather than tidiness. The Vulkan ICD runs inside somebody else's
    // process and has to reach the same pool file through the same block
    // semantics as the engine that created it. If the driver carried its own
    // copy of the tier ladder or its own Win32 wrappers, the two would drift
    // and the driver would advertise capacity the pool never agreed to.
    //
    // They are anonymous imports rather than relative `@import("../win.zig")`
    // inside the backend files because a relative import cannot escape its
    // module's root directory -- which is exactly what the ICD would need.
    // Shared modules.
    //
    // `win`, `tiers`, `blockdev` and `alloc` are built once and imported by
    // everyone, which is a correctness property rather than tidiness: the Vulkan
    // ICD runs inside somebody else's process and has to reach the same pool
    // file through the same block semantics as the engine that created it. If
    // the driver carried its own copy of the tier ladder or its own Win32
    // wrappers, the two would drift, and the driver would advertise capacity
    // the pool never agreed to.
    //
    // They are named imports rather than a relative `@import("../win.zig")`
    // inside the backend files because a relative import cannot escape its
    // module's root directory -- which is exactly what the ICD would need.
    const win_mod = b.createModule(.{
        .root_source_file = b.path("src/win.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });

    const tiers_mod = b.createModule(.{
        .root_source_file = b.path("src/backend/tiers.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });

    const blockdev_mod = b.createModule(.{
        .root_source_file = b.path("src/backend/blockdev.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    blockdev_mod.addImport("win", win_mod);
    blockdev_mod.addImport("tiers", tiers_mod);

    const alloc_mod = b.createModule(.{
        .root_source_file = b.path("src/backend/alloc.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    alloc_mod.addImport("win", win_mod);
    alloc_mod.addImport("blockdev", blockdev_mod);
    alloc_mod.addImport("tiers", tiers_mod);

    // Release-optimised twins for the two artefacts that are measured or shipped.
    // Same sources; only the optimise mode differs.
    const bench_win = b.createModule(.{
        .root_source_file = b.path("src/win.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    const bench_tiers = b.createModule(.{
        .root_source_file = b.path("src/backend/tiers.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    const bench_blockdev = b.createModule(.{
        .root_source_file = b.path("src/backend/blockdev.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    bench_blockdev.addImport("win", bench_win);
    bench_blockdev.addImport("tiers", bench_tiers);
    const bench_alloc = b.createModule(.{
        .root_source_file = b.path("src/backend/alloc.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    bench_alloc.addImport("win", bench_win);
    bench_alloc.addImport("blockdev", bench_blockdev);
    bench_alloc.addImport("tiers", bench_tiers);

    const icd_win = b.createModule(.{
        .root_source_file = b.path("src/win.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .link_libc = true,
    });
    const icd_tiers = b.createModule(.{
        .root_source_file = b.path("src/backend/tiers.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .link_libc = true,
    });
    const icd_blockdev = b.createModule(.{
        .root_source_file = b.path("src/backend/blockdev.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .link_libc = true,
    });
    icd_blockdev.addImport("win", icd_win);
    icd_blockdev.addImport("tiers", icd_tiers);
    const icd_alloc = b.createModule(.{
        .root_source_file = b.path("src/backend/alloc.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .link_libc = true,
    });
    icd_alloc.addImport("win", icd_win);
    icd_alloc.addImport("blockdev", icd_blockdev);
    icd_alloc.addImport("tiers", icd_tiers);

    // ------------------------------------------------------------------ engine
    //
    // The module root is the package directory, not src/. That is what lets
    // @embedFile reach ../web and compile the dashboard into the executable.
    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root.addImport("win", win_mod);
    root.addImport("tiers", tiers_mod);
    root.addImport("blockdev", blockdev_mod);
    root.addImport("alloc", alloc_mod);

    // PDH for counters, PSAPI for per-process memory, Winsock for the dashboard
    // socket. These are the only three external dependencies in the project.
    root.linkSystemLibrary("pdh", .{});
    root.linkSystemLibrary("psapi", .{});
    root.linkSystemLibrary("ws2_32", .{});

    const exe = b.addExecutable(.{
        .name = "dpu",
        .root_module = root,
    });

    // The web assets live in their own package so @embedFile can use paths
    // relative to web/ rather than src/.
    root.addAnonymousImport("web_assets", .{
        .root_source_file = b.path("web/assets.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);

    const run_step = b.step("run", "Run the DPU dashboard engine");
    run_step.dependOn(&run.step);

    // ------------------------------------------------------------------- tests
    //
    // The test root lives in src/ so that both `win` and the `backend/`
    // subdirectory resolve as siblings rather than parent-relative imports.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/backend_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport("win", win_mod);
    test_mod.addImport("tiers", tiers_mod);
    test_mod.addImport("blockdev", blockdev_mod);
    test_mod.addImport("alloc", alloc_mod);
    test_mod.linkSystemLibrary("pdh", .{});
    test_mod.linkSystemLibrary("psapi", .{});
    test_mod.linkSystemLibrary("ws2_32", .{});
    // cImport of the vendored Vulkan headers needs the third_party include
    // root, otherwise @cInclude("vulkan/vulkan_core.h") cannot resolve.
    test_mod.addIncludePath(b.path("third_party"));

    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run backend unit and integration tests");
    test_step.dependOn(&run_tests.step);

    // The tier ladder's tests live in tiers.zig, next to the policy they
    // describe. They need their own root because Zig only discovers tests in
    // the root module and its relative imports -- `tiers` is a *named* module,
    // so `zig build test` stopped running them the moment the backend started
    // sharing that source with the ICD. Thirteen tests went quiet, which is
    // exactly the kind of silent coverage loss a build step should not have.
    const tiers_tests = b.addTest(.{ .root_module = tiers_mod });
    const run_tiers_tests = b.addRunArtifact(tiers_tests);
    test_step.dependOn(&run_tiers_tests.step);

    // Likewise for the driver: memory.zig's alignment and heap-index
    // assertions are only reachable when the ICD itself is the test root.
    const icd_test_mod = b.createModule(.{
        .root_source_file = b.path("src/backend/icd/icd.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    icd_test_mod.addIncludePath(b.path("third_party"));
    icd_test_mod.addImport("win", win_mod);
    icd_test_mod.addImport("tiers", tiers_mod);
    icd_test_mod.addImport("blockdev", blockdev_mod);
    icd_test_mod.addImport("alloc", alloc_mod);
    const icd_tests = b.addTest(.{ .root_module = icd_test_mod });
    const run_icd_tests = b.addRunArtifact(icd_tests);
    test_step.dependOn(&run_icd_tests.step);

    // The Vulkan ABI assertions live in their own module because they are a
    // self-contained claim about the headers, and keeping them separate means a
    // header upgrade fails on its own rather than inside the backend suite.
    const abi_mod = b.createModule(.{
        .root_source_file = b.path("src/backend/icd/vkabi_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    abi_mod.addIncludePath(b.path("third_party"));
    const abi_tests = b.addTest(.{ .root_module = abi_mod });
    const abi_step = b.step("test-vkabi", "Assert the vendored Vulkan headers match the 1.3 ABI");
    abi_step.dependOn(&b.addRunArtifact(abi_tests).step);

    // ---------------------------------------------------------------- benchmark
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    bench_mod.addImport("win", bench_win);
    bench_mod.addImport("tiers", bench_tiers);
    bench_mod.addImport("blockdev", bench_blockdev);
    bench_mod.addImport("alloc", bench_alloc);
    bench_mod.linkSystemLibrary("pdh", .{});
    bench_mod.linkSystemLibrary("psapi", .{});

    const bench = b.addExecutable(.{ .name = "dpubench", .root_module = bench_mod });
    const run_bench = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Measure real flushed P:\\ device throughput");
    bench_step.dependOn(&run_bench.step);

    // --------------------------------------------------------------- Vulkan ICD
    //
    // A user-mode ICD needs no kernel driver and no signing, which is the only
    // reason it loads on this machine: HVCI is on and there is no WDK.
    //
    // It imports the same blockdev and alloc the engine uses. That is what
    // turns the advertised heap into real bytes on P:\ rather than a number in
    // a struct: vkAllocateMemory ends up in exactly the allocator that carved
    // the pool, and a failure to honour the 2 GiB reserve is a failure in one
    // place rather than two.
    const icd_mod = b.createModule(.{
        .root_source_file = b.path("src/backend/icd/icd.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    icd_mod.addIncludePath(b.path("third_party"));
    icd_mod.addImport("win", icd_win);
    icd_mod.addImport("tiers", icd_tiers);
    icd_mod.addImport("blockdev", icd_blockdev);
    icd_mod.addImport("alloc", icd_alloc);
    icd_mod.linkSystemLibrary("pdh", .{});
    icd_mod.linkSystemLibrary("psapi", .{});

    const icd = b.addLibrary(.{
        .name = "dpu_icd",
        .linkage = .dynamic,
        .root_module = icd_mod,
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
    });
    // The loader resolves entry points by name through the export table, so
    // nothing may be stripped or hidden.
    icd.root_module.linkSystemLibrary("kernel32", .{});

    const install_icd = b.addInstallArtifact(icd, .{});

    // ---------------------------------------------------------------- manifest
    //
    // The manifest is generated rather than checked in, because the only field
    // that matters is `library_path` and a hand-written one goes stale the
    // moment the output directory moves. It is written next to the DLL so a
    // relative library_path resolves, which keeps the pair portable: copy the
    // two files anywhere and the loader still finds them.
    const manifest_writer = b.addWriteFiles();
    const manifest = manifest_writer.add("vk_icd.json",
        "{\"file_format_version\":\"1.0.0\",\"ICD\":{\"library_path\":\".\\\\dpu_icd.dll\",\"api_version\":\"1.3\"}}");
    const install_manifest = b.addInstallFileWithDir(manifest, .bin, "vk_icd.json");

    // ---------------------------------------------------------------- launcher
    //
    // Building the driver does not register it, and registration is not a build
    // step. Two facts forced this shape, both learned by watching the loader
    // with VK_LOADER_DEBUG=all:
    //
    //   1. The Windows loader reads driver manifests from
    //      HKLM\SOFTWARE\Khronos\Vulkan\Drivers and from VK_ADD_DRIVER_FILES.
    //      It does NOT read HKCU for drivers -- only for layers. A per-user
    //      registry key for a driver is silently ignored, so this project does
    //      not pretend to offer one.
    //
    //   2. HKLM needs administrator rights and would advertise the DPU to every
    //      Vulkan application on the machine. That is the opposite of what this
    //      is for: the DPU exists for llama.cpp, so it is attached per process.
    //
    // So the deliverable is a launcher. It sets VK_ADD_DRIVER_FILES for one
    // command and exits, leaving nothing behind for other programs to inherit.
    const launcher = manifest_writer.add("dpu-vulkan.cmd",
        "@echo off\r\nrem Run a Vulkan application with the DPU visible to it, and to nothing else.\r\nrem\r\nrem   dpu-vulkan.cmd llama-server.exe --model ggml-org-model.gguf\r\nrem\r\nrem VK_ADD_DRIVER_FILES (not VK_DRIVER_FILES) appends to the drivers the loader\r\nrem already found, so the real GPU stays visible alongside the DPU.\r\nsetlocal\r\nset \"VK_ADD_DRIVER_FILES=%~dp0vk_icd.json\"\r\n%*");
    const install_launcher = b.addInstallFileWithDir(launcher, .bin, "dpu-vulkan.cmd");

    const icd_step = b.step("icd", "Build dpu_icd.dll + vk_icd.json + dpu-vulkan.cmd");
    icd_step.dependOn(&install_icd.step);
    icd_step.dependOn(&install_manifest.step);
    icd_step.dependOn(&install_launcher.step);

    // ------------------------------------------------------------- conformance
    //
    // Loads the real Vulkan loader against the freshly built driver and asserts
    // the DPU enumerates with the heap the engine published. Everything else in
    // this build can be green while the driver is silently absent -- a missing
    // export or a malformed manifest produces no build error at all, it just
    // makes the device not exist.
    const probe_mod = b.createModule(.{
        .root_source_file = b.path("src/backend/icd/probe.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    // Deliberately NOT linked against vulkan-1. The probe loads the loader with
    // LoadLibraryW and resolves entry points through vkGetInstanceProcAddr,
    // which is how an application really does it -- and linking would bake in a
    // loader from build time rather than the one installed on the machine.
    probe_mod.addImport("win", win_mod);
    // Link against the loader rather than resolving it at runtime; see the
    // comment in probe.zig. The import library is generated from the .def in
    // third_party because there is no Vulkan SDK on this machine.
    probe_mod.addLibraryPath(b.path("third_party"));
    probe_mod.addIncludePath(b.path("third_party"));
    probe_mod.linkSystemLibrary("kernel32", .{});
    probe_mod.linkSystemLibrary("vulkan-1", .{});
    const probe = b.addExecutable(.{ .name = "dpu_probe", .root_module = probe_mod });
    const install_probe = b.addInstallArtifact(probe, .{});

    const run_probe = b.addRunArtifact(probe);
    run_probe.step.dependOn(&install_probe.step);
    run_probe.step.dependOn(&install_manifest.step);
    run_probe.step.dependOn(&install_icd.step);
    // The loader finds drivers in HKLM and in VK_ADD_DRIVER_FILES, never in
    // HKCU. The probe sets the variable for itself so it does not depend on the
    // user having configured anything -- which is also the same mechanism
    // dpu-vulkan.cmd hands to llama.cpp.
    run_probe.setEnvironmentVariable(
        "VK_ADD_DRIVER_FILES",
        b.getInstallPath(.bin, "vk_icd.json"),
    );
    if (b.args) |args| run_probe.addArgs(args);

    const probe_step = b.step("probe", "Load the real Vulkan loader and verify the DPU enumerates");
    probe_step.dependOn(&run_probe.step);
}
