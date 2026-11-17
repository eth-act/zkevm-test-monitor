/*
 * _start invokes the C++ static constructors before main: the constructor of
 * a global object sets a value that main checks. The value comes from a
 * volatile variable, so the compiler cannot initialize the object at compile
 * time. The object has no destructor (see tests/eth-act-standards/README.md).
 */
#include "rt.h"

#define SOURCE 0x1234abcdu

static volatile uint32_t source = SOURCE;

class Constructed {
  public:
    Constructed() : value(~source) {}
    uint32_t value;
};

static Constructed constructed;

int main() {
    RT_CHECK(constructed.value == ~SOURCE, "the static constructor did not run before main");
    RT_WRITE("PASS");
    return 0;
}
