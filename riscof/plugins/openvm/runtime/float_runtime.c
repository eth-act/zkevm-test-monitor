// Simplified OpenVM Float Runtime for RISCOF Testing
// This version omits FCSR functionality for compatibility with -nostdlib compilation

#include <stdint.h>

// Memory-mapped register spaces
#define FLOAT_REG_BASE 0xC0000000
#define XREG_BASE 0xA0000000

// Helper macros
#define freg_ptr(n) ((volatile float *)(FLOAT_REG_BASE + ((n) * 4)))
#define xreg(n) (*(volatile uint32_t *)(XREG_BASE + ((n) * 16)))

// Soft-float LLVM compiler-rt functions
extern float __addsf3(float, float);
extern float __subsf3(float, float);
extern float __mulsf3(float, float);
extern float __divsf3(float, float);
extern int __eqsf2(float, float);
extern int __ltsf2(float, float);
extern int __lesf2(float, float);
extern int __fixsfsi(float);
extern unsigned int __fixunssfsi(float);
extern float __floatsisf(int);
extern float __floatunsisf(unsigned int);

// Placeholder for sqrtf - will use Newton-Raphson approximation
static float sqrtf_approx(float x) {
    if (x == 0.0f || x != x) return x;  // Handle 0 and NaN
    if (x < 0.0f) return 0.0f / 0.0f;   // Return NaN for negative

    float guess = x;
    for (int i = 0; i < 10; i++) {
        guess = __mulsf3(__addsf3(guess, __divsf3(x, guess)), 0.5f);
    }
    return guess;
}

// Helpers
static inline float read_freg_f32(uint32_t reg) {
    return *freg_ptr(reg);
}

static inline void write_freg_f32(uint32_t reg, float value) {
    *freg_ptr(reg) = value;
}

// Float operations (ignoring rounding mode for RISCOF)
void _openvm_fadd_s(uint32_t rs1, uint32_t rs2, uint32_t rd, uint32_t rm) {
    float a = read_freg_f32(rs1);
    float b = read_freg_f32(rs2);
    write_freg_f32(rd, __addsf3(a, b));
}

void _openvm_fsub_s(uint32_t rs1, uint32_t rs2, uint32_t rd, uint32_t rm) {
    float a = read_freg_f32(rs1);
    float b = read_freg_f32(rs2);
    write_freg_f32(rd, __subsf3(a, b));
}

void _openvm_fmul_s(uint32_t rs1, uint32_t rs2, uint32_t rd, uint32_t rm) {
    float a = read_freg_f32(rs1);
    float b = read_freg_f32(rs2);
    write_freg_f32(rd, __mulsf3(a, b));
}

void _openvm_fdiv_s(uint32_t rs1, uint32_t rs2, uint32_t rd, uint32_t rm) {
    float a = read_freg_f32(rs1);
    float b = read_freg_f32(rs2);
    write_freg_f32(rd, __divsf3(a, b));
}

void _openvm_fsqrt_s(uint32_t rs1, uint32_t rs2, uint32_t rd, uint32_t rm) {
    float a = read_freg_f32(rs1);
    write_freg_f32(rd, sqrtf_approx(a));
}

void _openvm_fmin_s(uint32_t rs1, uint32_t rs2, uint32_t rd, uint32_t rm) {
    float a = read_freg_f32(rs1);
    float b = read_freg_f32(rs2);
    // NaN handling: return non-NaN operand, or canonical NaN if both NaN
    int a_is_nan = (a != a);
    int b_is_nan = (b != b);
    if (a_is_nan && b_is_nan) write_freg_f32(rd, 0.0f / 0.0f);
    else if (a_is_nan) write_freg_f32(rd, b);
    else if (b_is_nan) write_freg_f32(rd, a);
    else write_freg_f32(rd, (__ltsf2(a, b) < 0) ? a : b);
}

void _openvm_fmax_s(uint32_t rs1, uint32_t rs2, uint32_t rd, uint32_t rm) {
    float a = read_freg_f32(rs1);
    float b = read_freg_f32(rs2);
    // NaN handling: return non-NaN operand, or canonical NaN if both NaN
    int a_is_nan = (a != a);
    int b_is_nan = (b != b);
    if (a_is_nan && b_is_nan) write_freg_f32(rd, 0.0f / 0.0f);
    else if (a_is_nan) write_freg_f32(rd, b);
    else if (b_is_nan) write_freg_f32(rd, a);
    else write_freg_f32(rd, (__ltsf2(a, b) > 0) ? a : b);
}

// FMA operations (using separate mul+add, not true FMA)
void _openvm_fmadd_s(uint32_t rs1, uint32_t rs2, uint32_t rs3, uint32_t rd, uint32_t rm) {
    float a = read_freg_f32(rs1);
    float b = read_freg_f32(rs2);
    float c = read_freg_f32(rs3);
    write_freg_f32(rd, __addsf3(__mulsf3(a, b), c));
}

void _openvm_fmsub_s(uint32_t rs1, uint32_t rs2, uint32_t rs3, uint32_t rd, uint32_t rm) {
    float a = read_freg_f32(rs1);
    float b = read_freg_f32(rs2);
    float c = read_freg_f32(rs3);
    write_freg_f32(rd, __subsf3(__mulsf3(a, b), c));
}

void _openvm_fnmadd_s(uint32_t rs1, uint32_t rs2, uint32_t rs3, uint32_t rd, uint32_t rm) {
    float a = read_freg_f32(rs1);
    float b = read_freg_f32(rs2);
    float c = read_freg_f32(rs3);
    write_freg_f32(rd, __subsf3(-__mulsf3(a, b), c));
}

void _openvm_fnmsub_s(uint32_t rs1, uint32_t rs2, uint32_t rs3, uint32_t rd, uint32_t rm) {
    float a = read_freg_f32(rs1);
    float b = read_freg_f32(rs2);
    float c = read_freg_f32(rs3);
    write_freg_f32(rd, __subsf3(-__mulsf3(a, b), -c));
}

// Sign injection operations
void _openvm_fsgnj_s(uint32_t rs1, uint32_t rs2, uint32_t rd, uint32_t rm) {
    uint32_t a = *(uint32_t *)freg_ptr(rs1);
    uint32_t b = *(uint32_t *)freg_ptr(rs2);
    uint32_t result = (a & 0x7FFFFFFF) | (b & 0x80000000);
    *(uint32_t *)freg_ptr(rd) = result;
}

void _openvm_fsgnjn_s(uint32_t rs1, uint32_t rs2, uint32_t rd, uint32_t rm) {
    uint32_t a = *(uint32_t *)freg_ptr(rs1);
    uint32_t b = *(uint32_t *)freg_ptr(rs2);
    uint32_t result = (a & 0x7FFFFFFF) | ((~b) & 0x80000000);
    *(uint32_t *)freg_ptr(rd) = result;
}

void _openvm_fsgnjx_s(uint32_t rs1, uint32_t rs2, uint32_t rd, uint32_t rm) {
    uint32_t a = *(uint32_t *)freg_ptr(rs1);
    uint32_t b = *(uint32_t *)freg_ptr(rs2);
    uint32_t result = a ^ (b & 0x80000000);
    *(uint32_t *)freg_ptr(rd) = result;
}

// Comparison operations (return to integer register via a0)
void _openvm_feq_s(uint32_t rs1, uint32_t rs2, uint32_t rm) {
    float a = read_freg_f32(rs1);
    float b = read_freg_f32(rs2);
    xreg(10) = (__eqsf2(a, b) == 0) ? 1 : 0;
}

void _openvm_flt_s(uint32_t rs1, uint32_t rs2, uint32_t rm) {
    float a = read_freg_f32(rs1);
    float b = read_freg_f32(rs2);
    xreg(10) = (__ltsf2(a, b) < 0) ? 1 : 0;
}

void _openvm_fle_s(uint32_t rs1, uint32_t rs2, uint32_t rm) {
    float a = read_freg_f32(rs1);
    float b = read_freg_f32(rs2);
    xreg(10) = (__lesf2(a, b) <= 0) ? 1 : 0;
}

// Conversion operations
void _openvm_fcvt_w_s(uint32_t rs1, uint32_t rs2, uint32_t rm) {
    float a = read_freg_f32(rs1);
    xreg(10) = (uint32_t)__fixsfsi(a);
}

void _openvm_fcvt_wu_s(uint32_t rs1, uint32_t rs2, uint32_t rm) {
    float a = read_freg_f32(rs1);
    xreg(10) = __fixunssfsi(a);
}

void _openvm_fcvt_s_w(uint32_t rs1, uint32_t rs2, uint32_t rd, uint32_t rm) {
    int32_t a = (int32_t)xreg(rs1);
    write_freg_f32(rd, __floatsisf(a));
}

void _openvm_fcvt_s_wu(uint32_t rs1, uint32_t rs2, uint32_t rd, uint32_t rm) {
    uint32_t a = xreg(rs1);
    write_freg_f32(rd, __floatunsisf(a));
}

// Move operations
void _openvm_fmv_x_w(uint32_t rs1, uint32_t rs2, uint32_t rm) {
    xreg(10) = *(uint32_t *)freg_ptr(rs1);
}

void _openvm_fmv_w_x(uint32_t rs1, uint32_t rs2, uint32_t rd, uint32_t rm) {
    *(uint32_t *)freg_ptr(rd) = xreg(rs1);
}

// FCLASS.S operation
void _openvm_fclass_s(uint32_t rs1, uint32_t rs2, uint32_t rm) {
    uint32_t bits = *(uint32_t *)freg_ptr(rs1);
    uint32_t exp = (bits >> 23) & 0xFF;
    uint32_t mant = bits & 0x7FFFFF;
    uint32_t sign = bits >> 31;

    uint32_t result = 0;
    if (exp == 0) {
        if (mant == 0) result = sign ? (1 << 3) : (1 << 4);  // -0 or +0
        else result = sign ? (1 << 2) : (1 << 5);            // subnormal
    } else if (exp == 0xFF) {
        if (mant == 0) result = sign ? (1 << 0) : (1 << 7);  // -inf or +inf
        else result = (mant & 0x400000) ? (1 << 9) : (1 << 8);  // qNaN or sNaN
    } else {
        result = sign ? (1 << 1) : (1 << 6);  // -normal or +normal
    }
    xreg(10) = result;
}

// Dispatch table
typedef void (*float_op_fn)(uint32_t, uint32_t, uint32_t, uint32_t);

__attribute__((section(".float_dispatch_table")))
const float_op_fn openvm_float_dispatch_table[24] = {
    [0]  = _openvm_fadd_s,
    [1]  = _openvm_fsub_s,
    [2]  = _openvm_fmul_s,
    [3]  = _openvm_fdiv_s,
    [4]  = _openvm_fsqrt_s,
    [5]  = _openvm_fmin_s,
    [6]  = _openvm_fmax_s,
    [7]  = (float_op_fn)_openvm_fmadd_s,
    [8]  = (float_op_fn)_openvm_fmsub_s,
    [9]  = (float_op_fn)_openvm_fnmadd_s,
    [10] = (float_op_fn)_openvm_fnmsub_s,
    [11] = _openvm_fsgnj_s,
    [12] = _openvm_fsgnjn_s,
    [13] = _openvm_fsgnjx_s,
    [14] = (float_op_fn)_openvm_feq_s,
    [15] = (float_op_fn)_openvm_flt_s,
    [16] = (float_op_fn)_openvm_fle_s,
    [17] = (float_op_fn)_openvm_fcvt_w_s,
    [18] = (float_op_fn)_openvm_fcvt_wu_s,
    [19] = _openvm_fcvt_s_w,
    [20] = _openvm_fcvt_s_wu,
    [21] = (float_op_fn)_openvm_fmv_x_w,
    [22] = _openvm_fmv_w_x,
    [23] = (float_op_fn)_openvm_fclass_s,
};
