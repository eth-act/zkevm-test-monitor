/*
 * Shared helpers for the accelerator tests.
 *
 * Each test includes a generated vectors/<function>.h that defines cases[],
 * then checks every case against its expectation (see gen_accel_vectors.py):
 *   EXPECT_OK      status ZKVM_EOK and the output equals the expected bytes
 *   EXPECT_TRUE    status ZKVM_EOK and verified == true
 *   EXPECT_REJECT  a failure status, or ZKVM_EOK with verified == false
 *   EXPECT_EFAIL   a failure status
 * A failing check reports id (case index + 1) * 16 + step.
 */
#ifndef ACCEL_H
#define ACCEL_H

#include "extra_test.h"
#include "zkvm_accelerators.h"

enum { EXPECT_OK, EXPECT_TRUE, EXPECT_REJECT, EXPECT_EFAIL };

#define NUM_CASES (sizeof cases / sizeof cases[0])

/* Steps within a case. */
#define STEP_STATUS 1
#define STEP_OUTPUT 2
#define STEP_VERDICT 3

#define CASE_ID(i, step) ((uint32_t)((i) + 1) * 16 + (step))

/* Output buffers start with a marker, so a function that writes nothing is caught. */
#define OUTPUT_MARKER 0xcc

static inline bool accel_status_ok(int expect, zkvm_status status) {
    switch (expect) {
    case EXPECT_OK:
    case EXPECT_TRUE:
        return status == ZKVM_EOK;
    case EXPECT_EFAIL:
        return status != ZKVM_EOK;
    default:
        return true;
    }
}

static inline bool accel_verdict_ok(int expect, zkvm_status status, bool verified) {
    if (expect == EXPECT_TRUE) {
        return status == ZKVM_EOK && verified;
    }
    return status != ZKVM_EOK || !verified;
}

/* Check a function that writes an output: status, then bytes when EXPECT_OK. */
#define CHECK_OUTPUT(i, status, out, want, len)                             \
    do {                                                                    \
        CHECK(CASE_ID(i, STEP_STATUS), accel_status_ok(cases[i].expect, status)); \
        if (cases[i].expect == EXPECT_OK) {                                 \
            CHECK(CASE_ID(i, STEP_OUTPUT), et_bytes_eq(out, want, len));    \
        }                                                                   \
    } while (0)

/* Check a function that reports a verified flag. */
#define CHECK_VERDICT(i, status, verified) \
    CHECK(CASE_ID(i, STEP_VERDICT), accel_verdict_ok(cases[i].expect, status, verified))

#endif /* ACCEL_H */
