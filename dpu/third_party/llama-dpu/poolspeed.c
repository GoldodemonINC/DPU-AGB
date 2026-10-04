// poolspeed.c -- is the pool mapping itself slow, or is it llama.cpp?
//
// The 9B run took 9.2 hours to load through the pool and 31 seconds without it.
// P: sustains 949 MB/s on a plain dd write, so the device is not the story.
// This removes llama.cpp from the picture entirely: same bytes, same memset,
// once from the pool mapping and once from malloc, timed against each other.
//
// If these two are close, the allocator is fine and the 9.2 hours belong to
// llama.cpp's access pattern. If the pool one is orders of magnitude slower,
// the mapping is the problem and the allocator needs a different design.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "ggml-dpu.h"

static double now(void) {
    LARGE_INTEGER f, c;
    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&c);
    return (double)c.QuadPart / (double)f.QuadPart;
}

static void banner(const char *what, double secs, size_t bytes) {
    printf("  %-28s %8.2f s   %7.1f MB/s\n", what, secs, (bytes / (1024.0 * 1024.0)) / secs);
}

int main(int argc, char **argv) {
    size_t mb = (argc > 1) ? (size_t)atol(argv[1]) : 2048;
    const size_t n = mb * 1024u * 1024u;

    printf("poolspeed: %zu MiB per case, GGML_DPU_POOL=%s\n",
           mb, getenv("GGML_DPU_POOL") ? getenv("GGML_DPU_POOL") : "(unset)");

    // malloc reference.
    {
        char *p = (char *)malloc(n);
        if (!p) { printf("malloc of %zu MiB failed\n", mb); return 1; }
        double t0 = now();
        memset(p, 1, n);
        double t1 = now();
        banner("malloc  + memset", t1 - t0, n);
        free(p);
    }

    // Pool mapping, through the same allocator llama.cpp uses.
    {
        char *p = (char *)ggml_dpu_malloc(n);
        if (!p) {
            printf("pool declined %zu MiB (falling back is normal)\n", mb);
            return 0;
        }
        double t0 = now();
        memset(p, 1, n);
        double t1 = now();
        banner("pool     + memset", t1 - t0, n);

        // Read it back, warm. This is the shape of every token: re-reading
        // weights that are already resident.
        //
        // Every byte is read, not one per page. A per-page probe measures how
        // fast the CPU walks a page table, not how fast bytes arrive, and
        // dividing the full length by that time reports a rate with no
        // relationship to a real read -- which is exactly what an earlier
        // version of this file did.
        double t2 = now();
        unsigned long long sum = 0;
        for (size_t i = 0; i < n; i++) sum += (unsigned char)p[i];
        double t3 = now();
        banner("pool     + warm read", t3 - t2, n);
        if (sum == 12345) printf("(never printed)\n");

        // A cold read is deliberately NOT measured here. MEM_RESET does not
        // apply to a file-backed view, and a user-mode program has no portable
        // way to evict its own file-backed pages from the system cache. An
        // earlier version called VirtualAlloc(MEM_RESET) here and got a number
        // of several hundred GB/s, which was the still-warm mapping being read
        // again. Printing the warm rate under a cold label would be worse than
        // printing nothing.

        ggml_dpu_free(p);
    }

    printf("  pool holds %zu bytes at exit\n", ggml_dpu_pool_bytes());
    return 0;
}