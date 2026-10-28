/*
 * Probe for the segment check of tools/check_static_library.py. The linker
 * script must assign the code sections (.text*, .init, .fini) to an
 * executable, non-writable segment, and every read-only data section
 * (.rodata*, .srodata*, .eh_frame*, .gcc_except_table, .data.rel.ro) to a
 * separate readable, non-executable segment.
 *
 * Each probe_* symbol is in one of these sections, and
 * -fasynchronous-unwind-tables gives .eh_frame. main uses every symbol, so
 * that --gc-sections keeps them. The probe is linked like the runtime guests,
 * but it does not run.
 */
#include "rt.h"

__attribute__((section(".text.rt_probe"), noipa)) int probe_text(int x) { return x + 1; }
__attribute__((section(".init"), noipa)) int probe_init(int x) { return x + 2; }
__attribute__((section(".fini"), noipa)) int probe_fini(int x) { return x + 3; }
__attribute__((section(".rodata.rt_probe"))) const volatile uint32_t probe_rodata = 4;
__attribute__((section(".srodata"))) const volatile uint32_t probe_srodata = 5;
__attribute__((section(".gcc_except_table"))) const volatile uint32_t probe_gcc_except_table = 6;
__attribute__((section(".data.rel.ro"))) const volatile uint32_t probe_data_rel_ro = 7;

int main(void) {
    volatile int sum = probe_text(0) + probe_init(0) + probe_fini(0) + (int)probe_rodata + (int)probe_srodata +
                       (int)probe_gcc_except_table + (int)probe_data_rel_ro;
    (void)sum;
    RT_WRITE("PASS");
    return 0;
}
