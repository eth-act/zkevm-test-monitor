/*
 * Replacement for optimized-routines string/test/mte.h (not vendored), for
 * the eth-act standards guests.
 *
 * RISC-V has no memory tagging, so this is the upstream non-MTE path, except
 * that mte_mmap takes memory from aor_arena: guests have no malloc. Each
 * wrapper (memory/mem-aor-*.c) defines aor_arena after it includes the test,
 * because the size depends on the test's LEN and A.
 */
#ifndef MTE_H
#define MTE_H

#include <stddef.h>

#include "c_test.h"

/* Guests have no abort(); the test calls it only for invalid parameters. */
#define abort() print_error("optimized-routines: abort\n")

extern unsigned char aor_arena[];
extern const size_t aor_arena_size;
static size_t aor_arena_used;

static void *
mte_mmap (size_t size)
{
  if (size > aor_arena_size - aor_arena_used)
    print_error ("optimized-routines: aor_arena is too small\n");
  void *p = aor_arena + aor_arena_used;
  aor_arena_used += size;
  return p;
}

static int
mte_enabled (void)
{
  return 0;
}

static void *
tag_buffer (void *p, int len, int test_mte)
{
  (void) len;
  (void) test_mte;
  return p;
}

static void *
untag_buffer (void *p, int len, int test_mte)
{
  (void) len;
  (void) test_mte;
  return p;
}

#endif
