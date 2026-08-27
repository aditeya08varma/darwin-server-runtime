#include "csystembridge.h"

/*
 * Returns 1 as a simple, fixed signal that this C target compiled and linked
 * into the Swift build. Real libarchive bindings arrive in Stage 2 and Mach
 * kernel task_info bindings arrive in Stage 4; this file is deliberately
 * empty of real logic until then.
 */
int csystembridge_ping(void) {
    return 1;
}
