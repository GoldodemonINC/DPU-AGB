// dputest.c -- prove the DPU pool allocator behaves before llama.cpp depends on it.
//
// The allocator's whole job is to be a correct allocator with a different
// backing store, so these checks are allocator checks: sizes round up, distinct
// live blocks do not overlap, a freed region is handed out again, and anything
// the pool did not hand out is left strictly alone so the caller can free it.
//
// Deliberately asserts things that are easy to get wrong and hard to notice:
// an off-by-one in the page rounding shows up as overlapping blocks here rather
// than as corrupted weights twenty minutes into a generation.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

// Whether the engine's pool mutex can be taken right now.
//
// The engine and the ICD need this mutex for every transfer and give up after
// a bounded wait, so an allocator that holds it from its first allocation to
// process exit starves the very thing that owns the pool -- for the whole of a
// generation, while owning nothing. That is not observable from inside the
// allocator, which always believes it holds the lock, so it is asked here
// instead: with nothing mapped out of the pool, taking the mutex must succeed.
//
// Fails for an unrelated reason if some other process happens to hold it; the
// suite is meant to run with the pool to itself.
static int pool_lock_is_free(void) {
    HANDLE h = CreateMutexW(NULL, FALSE, L"Local\\DPU.pool.lock");
    if (h == NULL) return 0;
    const DWORD wr = WaitForSingleObject(h, 0);
    const int ok = (wr == WAIT_OBJECT_0 || wr == WAIT_ABANDONED);
    if (ok) ReleaseMutex(h);
    CloseHandle(h);
    return ok;
}
#endif

#include "ggml-dpu.h"

static int checks = 0;
static int fails  = 0;

static void check(int ok, const char * what) {
    checks++;
    if (ok) {
        printf("  [ ok ] %s\n", what);
    } else {
        fails++;
        printf("  [FAIL] %s\n", what);
    }
}

#define MiB (1024u * 1024u)

// The pool is opt-in, so this test has two honest outcomes: with the env var
// set it must serve and recycle correctly, and without it the pool must decline
// everything and leave the caller's allocator in charge. A test that only
// passes in one of those is half a test.
static int pool_on(void) {
    const char *v = getenv("GGML_DPU_POOL");
    return v != NULL && (v[0] == '1' || v[0] == 'y' || v[0] == 'Y');
}

static void fill(unsigned char * p, size_t n, unsigned char seed) {
    for (size_t i = 0; i < n; i++) {
        p[i] = (unsigned char) (seed + (i * 31u));
    }
}

static int verify(const unsigned char * p, size_t n, unsigned char seed) {
    for (size_t i = 0; i < n; i++) {
        if (p[i] != (unsigned char) (seed + (i * 31u))) return 0;
    }
    return 1;
}

int main(void) {
    printf("dputest: GGML_DPU_POOL=%s\n",
           getenv("GGML_DPU_POOL") ? getenv("GGML_DPU_POOL") : "(unset)");

    // Below the threshold the pool must decline, so that the ordinary malloc
    // path keeps serving everything small.
    check(ggml_dpu_malloc(1024) == NULL, "a 1 KiB request is declined by the pool");

    if (!pool_on()) {
        check(ggml_dpu_malloc(64 * MiB) == NULL,
              "with GGML_DPU_POOL unset the pool declines a 64 MiB request");
        check(ggml_dpu_pool_bytes() == 0, "with GGML_DPU_POOL unset nothing is mapped");
        printf("\npool is off by design -- rerun with GGML_DPU_POOL=1 to exercise it\n");
        printf("%d/%d checks passed\n", checks - fails, checks);
        return fails == 0 ? 0 : 1;
    }

    unsigned char * a = (unsigned char *) ggml_dpu_malloc(64 * MiB);
    check(a != NULL, "a 64 MiB request is served from the pool");
    if (a == NULL) {
        printf("\n%d/%d checks passed\n", checks - fails, checks);
        return 1;
    }

    unsigned char * b = (unsigned char *) ggml_dpu_malloc(32 * MiB);
    check(b != NULL, "a second 32 MiB request is served alongside the first");
    if (b == NULL) {
        printf("\n%d/%d checks passed\n", checks - fails, checks);
        return 1;
    }

    // Overlap has to be checked on the pool FILE offsets. `a` and `b` are
    // separate mappings, so comparing the pointers with <= is undefined
    // behaviour, and disjoint addresses say nothing about whether the two
    // blocks reserved overlapping bytes in pool.vram.
    {
        size_t ao = 0, al = 0, bo = 0, bl = 0;
        check(ggml_dpu_block_span(a, &ao, &al) == 1, "block a reports its pool offset");
        check(ggml_dpu_block_span(b, &bo, &bl) == 1, "block b reports its pool offset");
        const int disjoint = (ao + al <= bo) || (bo + bl <= ao);
        check(disjoint, "two live blocks occupy disjoint byte ranges in the pool file");
    }

    // A size that is not a whole number of MiB is the case that matters for
    // mapping alignment: rounding to the 4 KiB page size leaves the next offset
    // at a boundary MapViewOfFile rejects, and the request after it fails even
    // though the pool is nearly empty. Both allocations below must be served.
    {
        unsigned char * d = (unsigned char *) ggml_dpu_malloc(5 * MiB + 4096u);
        check(d != NULL, "a 5 MiB + 4 KiB request is served");
        unsigned char * e = (unsigned char *) ggml_dpu_malloc(4 * MiB);
        check(e != NULL, "the request after a non-MiB-sized one is served (mapping alignment)");
        if (d != NULL) {
            size_t o = 0;
            check(ggml_dpu_block_span(d, &o, NULL) == 1 && (o % (64u * 1024u)) == 0,
                  "a block of an odd size still lands on a 64 KiB boundary");
            fill(d, 5 * MiB + 4096u, 23);
            check(verify(d, 5 * MiB + 4096u, 23), "the odd-sized block reads back intact");
            ggml_dpu_free(d);
        }
        if (e != NULL) ggml_dpu_free(e);
    }

    fill(a, 64 * MiB, 7);
    fill(b, 32 * MiB, 199);
    check(verify(a, 64 * MiB, 7), "64 MiB block reads back the bytes written to it");
    check(verify(b, 32 * MiB, 199), "32 MiB block reads back the bytes written to it");

    const size_t held = ggml_dpu_pool_bytes();
    check(held >= 96 * MiB, "the pool reports the bytes it is holding");

    check(ggml_dpu_free(a) == 1, "freeing a pool pointer is claimed by the pool");
    check(ggml_dpu_free(b) == 1, "freeing the second pool pointer is claimed");

    int stack_marker = 0;
    check(ggml_dpu_free(&stack_marker) == 0,
          "a pointer the pool never handed out is refused");

    // The 64 MiB and 32 MiB regions sit next to each other, so a request for
    // their sum can only succeed if free() coalesced them.
    unsigned char * c = (unsigned char *) ggml_dpu_malloc(96 * MiB);
    check(c != NULL, "96 MiB is served after freeing two adjacent blocks (coalescing)");
    if (c != NULL) {
        fill(c, 96 * MiB, 42);
        check(verify(c, 96 * MiB, 42), "the 96 MiB block reads back the bytes written to it");
        check(ggml_dpu_free(c) == 1, "the 96 MiB block is freed");
    }

    check(ggml_dpu_pool_bytes() == 0, "the pool is empty again at the end");
#ifdef _WIN32
    check(pool_lock_is_free(),
          "the engine's pool lock is released once nothing is mapped from the pool");
#endif

    printf("\n%d/%d checks passed\n", checks - fails, checks);
    return fails == 0 ? 0 : 1;
}