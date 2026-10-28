/*
 * reject-class32: an ELFCLASS32 program, which the loader must reject
 * ("Header validation": the class is ELFCLASS64). build-guests.sh builds it
 * for rv32i and links it at the zkVM's entry address, with the zkVM's
 * executable segment flags, so the class is the only header field that is
 * wrong. If a zkVM runs it anyway, the program makes one ecall with every
 * register at zero (SP1 halts on it). A breakpoint runs forever on SP1
 * through ere: its JIT logs the instruction and runs it again.
 */
    .section .text
    .globl _start
_start:
    ecall
