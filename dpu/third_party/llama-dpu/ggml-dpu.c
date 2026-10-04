// ggml-dpu.c -- serve ggml's large CPU allocations from the DPU pool.
//
// WHY THIS EXISTS
//
// Every tensor the CPU backend does not mmap comes from ggml_aligned_malloc,
// which on Windows is _aligned_malloc: private, anonymous memory, charged to
// the process commit until it is freed and never reclaimable by the memory
// manager. Weights loaded with --no-mmap, the KV cache and the per-graph
// compute buffers all take that path.
//
// That is the binding constraint on a small machine. An 8B Q4_K_M model is
// ~4.9 GiB of weights before a single KV cache exists, and this box has 8 GiB
// of RAM in total, so a model that fits "on disk" does not fit "in memory".
//
// DPU already maintains a heap of exactly the right shape at P:\DPU\pool.vram:
// a sparse file sized by the engine's granted tier (8 GiB by default) and
// guarded by a named lock so two writers cannot share it. Mapping it instead of
// calling the allocator makes the same bytes *file-backed*, which changes who
// pays for them: the page cache, which the memory manager can trim under
// pressure, rather than commit, which it cannot. The model still has to be read
// to run; what changes is that reading it no longer costs you the RAM a game
// would want.
//
// WHAT THIS DOES NOT DO
//
// It does not make inference faster, and it is not a Vulkan backend. Bytes in
// the pool still travel over the storage bus, so for a memory-bound workload
// this trades speed for headroom. It moves memory, nothing else. A device that
// executes compute is a separate piece of work, and this file is not it.
//
// Opt in with GGML_DPU_POOL=1. The default is off on purpose: silently moving a
// process's memory onto a disk is not something to do to someone who did not
// ask for it.

#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <windows.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ggml-dpu.h"

#if defined(_WIN32)

// The engine publishes the tier it granted in this file, and the ICD reads the
// same one. It is the authority on how large the pool may be; inventing a
// number here would mean llama.cpp and the engine disagreeing about the same
// file.
#define DPU_TIER_PATH   "P:\\DPU\\tier.cfg"
#define DPU_POOL_PATH   "P:\\DPU\\pool.vram"

// The lock the engine takes while it owns the pool. Taking it here is not
// politeness: two allocators handing out offsets into one file would collide,
// and a collision is silent corruption rather than a crash.
#define DPU_POOL_LOCK   "Local\\DPU.pool.lock"

// Mapping costs a page table entry and a syscall; below this size the malloc
// path is both faster and perfectly correct. The pool is for tensors.
#define DPU_MIN_ALLOC   (4u * 1024u * 1024u)

// The pool file is a Windows file and is addressed in 4 KiB pages.
#define DPU_GRAN        4096ull

// How long to wait for the engine to let go of the pool before giving up and
// serving everything from malloc. Waiting is better than failing: the engine is
// a short-lived process and almost always lets go immediately.
#define DPU_LOCK_WAIT_MS 5000

typedef struct {
    void    * base;  // what MapViewOfFile handed back; the key for ggml_dpu_free
    uint64_t off;   // where that view starts in the pool file
    uint64_t len;   // how many bytes are mapped
} dpu_block;

typedef struct {
    uint64_t off;
    uint64_t len;
} dpu_extent;

static HANDLE           g_file     = INVALID_HANDLE_VALUE;
static HANDLE           g_map      = NULL;
static HANDLE           g_lock     = NULL;
static uint64_t         g_cap      = 0;    // bytes addressable through g_map
static uint64_t         g_live_bytes = 0;

static dpu_extent     * g_free     = NULL; // sorted by off, coalesced, len > 0
static size_t           g_nfree    = 0;
static size_t           g_free_cap = 0;

static dpu_block      * g_blocks   = NULL;
static size_t           g_nblocks  = 0;
static size_t           g_blocks_cap = 0;

static CRITICAL_SECTION g_cs;
static volatile LONG    g_cs_state = 0;    // 0 uninitialised, 1 initialising, 2 ready
static int              g_state    = -1;   // -1 untried, 0 unavailable, 1 serving

// Instrumentation.
//
// ggml's graph allocator allocates and frees a buffer per node, so a single
// 9B model load makes an enormous number of calls against structures that are
// linear here. Those are the numbers that decide whether this allocator is
// usable at model scale or only in a test, so they are counted rather than
// guessed at. Printed once at exit when GGML_DPU_STATS=1.
static unsigned long long g_n_alloc    = 0;
static unsigned long long g_n_free     = 0;
static unsigned long long g_n_fallback = 0;
static size_t             g_max_live   = 0;
static size_t             g_max_free   = 0;
static unsigned long long g_scan_steps = 0;

// A hand-rolled one-time init. InitOnceExecuteOnce would do, but this keeps the
// dependency surface to windows.h and nothing else.
static void dpu_enter(void) {
    if (InterlockedCompareExchange(&g_cs_state, 1, 0) == 0) {
        InitializeCriticalSection(&g_cs);
        InterlockedExchange(&g_cs_state, 2);
    } else {
        while (InterlockedCompareExchange(&g_cs_state, 2, 0) != 2) {
            SwitchToThread();
        }
    }
    EnterCriticalSection(&g_cs);
}

static void dpu_leave(void) {
    LeaveCriticalSection(&g_cs);
}

// The tier the engine granted, in bytes, or 0 when it cannot be read.
//
// A missing tier.cfg is treated as "no pool" rather than as "assume some
// size": the engine has not run, so nothing has authorised a capacity, and
// guessing here would be how llama.cpp ends up writing into a pool the engine
// believes is a different size.
static uint64_t dpu_read_tier(void) {
    HANDLE f = CreateFileW(
        L"P:\\DPU\\tier.cfg",
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE) return 0;

    char   buf[256];
    DWORD  got = 0;
    BOOL   ok  = ReadFile(f, buf, (DWORD) sizeof(buf) - 1, &got, NULL);
    CloseHandle(f);
    if (!ok || got == 0) return 0;

    buf[got] = '\0';
    const char * p = strstr(buf, "tier_bytes=");
    if (p == NULL) return 0;

    return (uint64_t) strtoull(p + strlen("tier_bytes="), NULL, 10);
}

// Printed once at exit when GGML_DPU_STATS=1. The counters are what decide
// whether this allocator is usable at model scale: a linear scan that looks
// harmless in a unit test is quadratic once a graph allocator makes millions
// of calls against it.
static void dpu_stats_atexit(void) {
    dpu_enter();
    fprintf(stderr,
            "ggml-dpu: stats alloc=%llu free=%llu fallback=%llu"
            " max_live=%zu max_free=%zu scan_steps=%llu\n",
            g_n_alloc, g_n_free, g_n_fallback,
            g_max_live, g_max_free, g_scan_steps);
    dpu_leave();
}

static void dpu_extent_release(uint64_t off, uint64_t len) {
    // Insert keeping `off` ascending, then coalesce with both neighbours.
    size_t i = 0;
    while (i < g_nfree && g_free[i].off < off) i++;

    if (i < g_nfree && g_free[i].off == off) {
        g_free[i].len += len;
    } else {
        if (g_nfree + 1 > g_free_cap) {
            size_t             cap = g_free_cap ? g_free_cap * 2 : 16;
            dpu_extent * grown = (dpu_extent *) realloc(g_free, cap * sizeof(dpu_extent));
            if (grown == NULL) return;   // leaked region; correctness is intact
            g_free     = grown;
            g_free_cap = cap;
        }
        memmove(&g_free[i + 1], &g_free[i], (g_nfree - i) * sizeof(dpu_extent));
        g_free[i].off = off;
        g_free[i].len = len;
        g_nfree++;
    }

    // Merge forward.
    while (i + 1 < g_nfree && g_free[i].off + g_free[i].len == g_free[i + 1].off) {
        g_free[i].len += g_free[i + 1].len;
        memmove(&g_free[i + 1], &g_free[i + 2], (g_nfree - i - 2) * sizeof(dpu_extent));
        g_nfree--;
    }
    // Merge backward.
    while (i > 0 && g_free[i - 1].off + g_free[i - 1].len == g_free[i].off) {
        g_free[i - 1].len += g_free[i].len;
        memmove(&g_free[i], &g_free[i + 1], (g_nfree - i - 1) * sizeof(dpu_extent));
        g_nfree--;
        i--;
    }
}

// Bring the pool up if it is wanted and usable. Called with the lock held.
static int dpu_init(void) {
    if (g_state >= 0) return g_state;
    g_state = 0;   // any failure below leaves the pool off

    const char * want = getenv("GGML_DPU_POOL");
    if (want == NULL || (want[0] != '1' && want[0] != 'y' && want[0] != 'Y')) {
        return 0;
    }

    const uint64_t tier = dpu_read_tier();
    if (tier == 0) {
        fprintf(stderr, "ggml-dpu: %s unreadable or absent, serving from malloc\n", DPU_TIER_PATH);
        return 0;
    }

    g_lock = CreateMutexW(NULL, FALSE, L"Local\\DPU.pool.lock");
    if (g_lock == NULL) {
        fprintf(stderr, "ggml-dpu: could not create the pool lock, serving from malloc\n");
        return 0;
    }
    const DWORD wr = WaitForSingleObject(g_lock, DPU_LOCK_WAIT_MS);
    if (wr != WAIT_OBJECT_0 && wr != WAIT_ABANDONED) {
        fprintf(stderr, "ggml-dpu: another process owns the pool, serving from malloc\n");
        CloseHandle(g_lock);
        g_lock = NULL;
        return 0;
    }
    // WAIT_ABANDONED means the previous owner died holding it; we now own it.

    g_file = CreateFileW(
        L"P:\\DPU\\pool.vram",
        GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (g_file == INVALID_HANDLE_VALUE) {
        fprintf(stderr, "ggml-dpu: cannot open %s, serving from malloc\n", DPU_POOL_PATH);
        goto unlock;
    }

    // The pool file is sparse and is never preallocated -- it grows as it is
    // used. A mapping cannot reach past the end of a file, so the length has to
    // be out to the tier before the first view is created. On a sparse volume
    // this sets the logical size only; the bytes are not there until written.
    LARGE_INTEGER li;
    li.QuadPart = (LONGLONG) tier;
    if (!SetFilePointerEx(g_file, li, NULL, FILE_BEGIN) || !SetEndOfFile(g_file)) {
        fprintf(stderr, "ggml-dpu: cannot size the pool to %llu bytes, serving from malloc\n",
                (unsigned long long) tier);
        goto close_file;
    }

    g_map = CreateFileMappingW(g_file, NULL, PAGE_READWRITE, 0, 0, NULL);
    if (g_map == NULL) {
        fprintf(stderr, "ggml-dpu: cannot map the pool, serving from malloc\n");
        goto close_file;
    }
    g_cap = tier;

    if (g_free_cap == 0) {
        g_free = (dpu_extent *) malloc(sizeof(dpu_extent));
        if (g_free == NULL) goto unmap;
        g_free_cap = 1;
    }
    g_free[0].off = 0;
    g_free[0].len = g_cap;
    g_nfree       = 1;

    g_state = 1;
    {
        static int stats_registered = 0;
        const char * want_stats = getenv("GGML_DPU_STATS");
        if (!stats_registered && want_stats != NULL && want_stats[0] == '1') {
            stats_registered = 1;
            atexit(dpu_stats_atexit);
        }
    }
    fprintf(stderr,
            "ggml-dpu: pool %s, tier %.2f GiB, serving allocations >= %u MiB from disk\n",
            DPU_POOL_PATH, (double) tier / (1024.0 * 1024.0 * 1024.0),
            (unsigned) (DPU_MIN_ALLOC / (1024u * 1024u)));
    return 1;

unmap:
    CloseHandle(g_map);
    g_map = NULL;
close_file:
    CloseHandle(g_file);
    g_file = INVALID_HANDLE_VALUE;
unlock:
    ReleaseMutex(g_lock);
    CloseHandle(g_lock);
    g_lock = NULL;
    return 0;
}

void * ggml_dpu_malloc(size_t size) {
    if (size < DPU_MIN_ALLOC) { g_n_fallback++; return NULL; }

    dpu_enter();
    if (!dpu_init()) { dpu_leave(); return NULL; }

    const uint64_t need = ((uint64_t) size + DPU_GRAN - 1) / DPU_GRAN * DPU_GRAN;

    // Find a home for it before anything is changed, so every failure below is
    // a clean return rather than a half-applied edit to the free list.
    size_t idx = (size_t) -1;
    for (size_t i = 0; i < g_nfree; i++) {
        g_scan_steps++;
        if (g_free[i].len >= need) { idx = i; break; }
    }
    if (idx == (size_t) -1) {
        dpu_leave();
        return NULL;   // pool exhausted: the caller falls back to malloc
    }

    size_t slot = (size_t) -1;
    if (g_nblocks == g_blocks_cap) {
        size_t        cap   = g_blocks_cap ? g_blocks_cap * 2 : 32;
        dpu_block * grown = (dpu_block *) realloc(g_blocks, cap * sizeof(dpu_block));
        if (grown == NULL) { dpu_leave(); return NULL; }
        g_blocks     = grown;
        g_blocks_cap = cap;
    }
    slot = g_nblocks;

    const dpu_extent e = g_free[idx];
    void * base = MapViewOfFile(
        g_map, FILE_MAP_ALL_ACCESS,
        (DWORD) (e.off >> 32), (DWORD) (e.off & 0xffffffffu),
        (SIZE_T) need);
    if (base == NULL) { dpu_leave(); return NULL; }

    // Commit: the region is ours, so take it out of the free list and record it.
    g_free[idx].off = e.off + need;
    g_free[idx].len = e.len - need;
    if (g_free[idx].len == 0) {
        g_free[idx] = g_free[g_nfree - 1];
        g_nfree--;
    }

    g_blocks[slot].base = base;
    g_blocks[slot].off  = e.off;
    g_blocks[slot].len  = need;
    g_nblocks++;
    g_live_bytes += need;
    g_n_alloc++;
    if (g_nblocks > g_max_live) g_max_live = g_nblocks;
    if (g_nfree   > g_max_free) g_max_free = g_nfree;

    dpu_leave();
    return base;
}

int ggml_dpu_free(void * ptr) {
    if (ptr == NULL) return 0;

    dpu_enter();
    if (g_state != 1) { dpu_leave(); return 0; }

    size_t found = (size_t) -1;
    for (size_t i = 0; i < g_nblocks; i++) {
        g_scan_steps++;
        if (g_blocks[i].base == ptr) { found = i; break; }
    }
    if (found == (size_t) -1) { dpu_leave(); return 0; }

    const dpu_block b = g_blocks[found];
    g_blocks[found] = g_blocks[--g_nblocks];
    g_live_bytes   -= b.len;

    UnmapViewOfFile(ptr);
    dpu_extent_release(b.off, b.len);
    g_n_free++;
    if (g_nfree > g_max_free) g_max_free = g_nfree;

    dpu_leave();
    return 1;
}

size_t ggml_dpu_pool_bytes(void) {
    dpu_enter();
    const int    on  = dpu_init();
    const size_t out = on ? (size_t) g_live_bytes : 0;
    dpu_leave();
    return out;
}

#else // !_WIN32

// Not Windows, not the DPU. Every entry point stays, so ggml.c needs no
// conditional compilation of its own beyond the one guard it already has.
void * ggml_dpu_malloc(size_t size)          { (void) size; return NULL; }
int    ggml_dpu_free (void * ptr)           { (void) ptr;  return 0;    }
size_t ggml_dpu_pool_bytes(void)            { return 0; }

#endif // _WIN32