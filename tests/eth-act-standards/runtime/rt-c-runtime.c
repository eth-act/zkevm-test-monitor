/*
 * _start performs all machine initialization required before C code can
 * execute. At main, initialized .data, .sdata and .rodata hold their values,
 * .bss and .sbss hold written values, and the stack holds the locals of a
 * short call chain.
 */
#include "rt.h"

#define WORD 0x0123456789abcdefULL
#define SMALL 0x5a17c3e1u
#define DEPTH 8
#define LOCALS 8

__attribute__((section(".data"))) static volatile uint64_t in_data[4] = {WORD, ~WORD, WORD >> 8, WORD << 8};
__attribute__((section(".sdata"))) static volatile uint32_t in_sdata = SMALL;
__attribute__((section(".rodata"))) static const volatile uint64_t in_rodata[4] = {~WORD, WORD, WORD << 8, WORD >> 8};
__attribute__((section(".bss"))) static volatile uint64_t in_bss[4];
__attribute__((section(".sbss"))) static volatile uint32_t in_sbss;

/* Each frame fills its locals, calls the next frame and then checks its
   locals. Returns 1 when every frame kept its locals. */
__attribute__((noipa)) static int call_chain(unsigned depth) {
    volatile uint64_t local[LOCALS];
    for (unsigned i = 0; i < LOCALS; i++) {
        local[i] = WORD ^ (depth * LOCALS + i);
    }
    int ok = depth == 0 ? 1 : call_chain(depth - 1);
    for (unsigned i = 0; i < LOCALS; i++) {
        ok &= local[i] == (WORD ^ (depth * LOCALS + i));
    }
    return ok;
}

int main(void) {
    RT_CHECK(in_data[0] == WORD && in_data[1] == ~WORD && in_data[2] == WORD >> 8 && in_data[3] == WORD << 8,
             ".data does not hold its initial value");
    RT_CHECK(in_sdata == SMALL, ".sdata does not hold its initial value");
    RT_CHECK(in_rodata[0] == ~WORD && in_rodata[1] == WORD && in_rodata[2] == WORD << 8 && in_rodata[3] == WORD >> 8,
             ".rodata does not hold its initial value");
    for (unsigned i = 0; i < 4; i++) {
        in_bss[i] = WORD + i;
    }
    for (unsigned i = 0; i < 4; i++) {
        RT_CHECK(in_bss[i] == WORD + i, ".bss does not hold a written value");
    }
    in_sbss = SMALL;
    RT_CHECK(in_sbss == SMALL, ".sbss does not hold a written value");
    RT_CHECK(call_chain(DEPTH), "the stack does not keep the locals of a call chain");
    RT_WRITE("PASS");
    return 0;
}
