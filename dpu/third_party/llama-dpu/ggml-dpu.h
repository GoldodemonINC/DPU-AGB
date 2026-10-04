// ggml-dpu.h -- serve ggml's large CPU allocations from the DPU pool.
//
// Opt in with GGML_DPU_POOL=1. Without it every function here is a no-op that
// returns NULL, and ggml_aligned_malloc/ggml_aligned_free keep their original
// behaviour byte for byte.

#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Map `size` bytes out of the DPU pool, or return NULL.
//
// NULL is not an error: it means the pool is switched off, unavailable,
// exhausted, or the request was too small to be worth mapping. Callers are
// expected to fall back to the ordinary allocator.
void * ggml_dpu_malloc(size_t size);

// Release a pointer previously returned by ggml_dpu_malloc.
// Returns 1 if the pointer came from the pool (and has now been unmapped),
// 0 if it did not, in which case the caller must free it normally.
int ggml_dpu_free(void * ptr);

// Bytes currently mapped out of the pool, or 0 when the pool is not in use.
size_t ggml_dpu_pool_bytes(void);

// The pool-file byte range backing `ptr`, written through `offset`/`length`.
// Returns 1 if the pointer came from the pool, 0 if it did not.
//
// Exists so a test can assert that two live blocks occupy disjoint byte ranges
// in the FILE. The returned pointers cannot answer that: they are separate
// mappings, so ordering them with `<=` is undefined behaviour, and two blocks
// may be disjoint in memory while sharing a range on disk. Only the offsets
// say what was actually reserved.
int ggml_dpu_block_span(const void * ptr, size_t * offset, size_t * length);

#ifdef __cplusplus
}
#endif