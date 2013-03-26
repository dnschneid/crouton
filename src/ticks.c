/* Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 *
 * Outputs the current value of CLOCK_MONOTIC in usecs.
 */

#include <time.h>
#include <stdio.h>

int main() {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t))
        return 1;
    unsigned long long micros = t.tv_sec * 1000000ULL + t.tv_nsec / 1000;
    printf("%llu\n", micros);
    return 0;
}
