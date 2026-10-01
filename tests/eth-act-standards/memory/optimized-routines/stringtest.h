/*
 * Replacement for optimized-routines string/test/stringtest.h (not vendored),
 * for the eth-act standards guests.
 *
 * It has the upstream error accounting and quoting, but its own isprint:
 * guests have no libc, so the newlib <ctype.h> macros do not link. printf
 * and putchar come from ACT's C test runtime (c_test.h).
 */
#ifndef STRINGTEST_H
#define STRINGTEST_H

#include "c_test.h"

/* Accounting errors for a test case.  */
static int err_count;
#define ERR_LIMIT 10
#define ERR(...) (err_count++, printf (__VA_ARGS__))

static inline void
quotechar (unsigned char c)
{
  if (c >= 0x20 && c < 0x7f)
    putchar (c);
  else
    printf ("\\x%02x", c);
}

/* quoted print around at or the entire string if at < 0.  */
static void
quoteat (const char *prefix, const void *p, int len, int at)
{
  static const int CTXLEN = 15;
  int i;
  const char *pre = "\"";
  const char *post = "\"";
  const char *s = p;
  if (at > CTXLEN)
    {
      s += at - CTXLEN;
      len -= at - CTXLEN;
      pre = "...\"";
    }
  if (at >= 0 && len > 2 * CTXLEN + 1)
    {
      len = 2 * CTXLEN + 1;
      post = "\"...";
    }
  printf ("%4s: %s", prefix, pre);
  for (i = 0; i < len; i++)
    quotechar (s[i]);
  printf ("%s\n", post);
}

#endif
