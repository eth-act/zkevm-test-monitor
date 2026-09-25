/* Output written in odd-sized pieces is observed as one concatenated stream. */
#include "test_verdict.h"
#include "pattern.h"

#define OUTPUT_SIZE 64

int main(void) {
    static const size_t pieces[] = {1, 3, 2, 5, 1, 7, 4, 6, 9, 11, 15};
    uint8_t data[OUTPUT_SIZE];
    for (size_t i = 0; i < OUTPUT_SIZE; i++) {
        data[i] = io_pattern(i);
    }
    size_t offset = 0;
    for (size_t p = 0; p < sizeof pieces / sizeof pieces[0]; p++) {
        write_output(data + offset, pieces[p]);
        offset += pieces[p];
    }
    return 0;
}
