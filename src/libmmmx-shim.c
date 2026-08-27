/*
 * libmmmx-shim: provides fmod@GLIBC_2.38 for old GLIBC systems
 *
 * Why: better-sqlite3 rebuilt on Ubuntu 24.04 (GLIBC 2.39) references
 *      fmod@GLIBC_2.38 (glibc 2.38 changed fmod's signature/versioned symbol).
 *      On Ubuntu 22.04 (jammy, GLIBC 2.35) and 20.04 (focal, GLIBC 2.31),
 *      the system libm.so.6 doesn't have this versioned symbol, so loading
 *      better_sqlite3.node fails with:
 *        /lib/x86_64-linux-gnu/libm.so.6: version `GLIBC_2.38' not found
 *
 * Fix: This shim provides a C99 implementation of fmod, exported with
 *      both GLIBC_2.38 and GLIBC_2.2.5 versioned symbols. Link it into
 *      better_sqlite3.node via -lmmmx + -Wl,-rpath during rebuild:
 *
 *        LDFLAGS: -Wl,-rpath,/opt/mmx-shared -L/opt/mmx-shared -lmmmx
 *
 *      Then deploy /opt/mmx-shared/libmmmx.so on the target system.
 *
 * Build: gcc -shared -fPIC -nostdlib -o libmmmx.so libmmmx-shim.c \
 *            -Wl,--version-script=libmmmx-shim.map
 */

#include <math.h>

double fmod(double x, double y) {
    /* C99 fmod: x - trunc(x/y) * y, avoiding libm fmod (which on GLIBC 2.39
       is fmod@GLIBC_2.38) by doing the math ourselves with no math symbols. */
    if (y == 0.0) return 0.0;
    double q = x / y;
    double t = (q >= 0.0) ? (double)(long long)q : (double)(long long)(q - 1.0);
    if (q < 0.0 && q == t) t -= 1.0;
    return x - t * y;
}

asm(".symver fmod,fmod@GLIBC_2.38");
asm(".symver fmod,fmod@GLIBC_2.2.5");
