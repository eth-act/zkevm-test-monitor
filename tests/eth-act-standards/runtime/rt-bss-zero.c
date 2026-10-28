/*
 * The BSS segment contains only zero bytes when main is entered: a 64 KiB
 * .bss array and a .sbss variable are zero at the start of main.
 */
#include "rt.h"

#define BSS_SIZE (64 * 1024)

__attribute__((section(".bss"))) static volatile uint8_t in_bss[BSS_SIZE];
__attribute__((section(".sbss"))) static volatile uint64_t in_sbss;

int main(void) {
    RT_CHECK(in_sbss == 0, ".sbss is not zero at main");
    for (size_t i = 0; i < BSS_SIZE; i++) {
        RT_CHECK(in_bss[i] == 0, ".bss is not zero at main");
    }
    RT_WRITE("PASS");
    return 0;
}
