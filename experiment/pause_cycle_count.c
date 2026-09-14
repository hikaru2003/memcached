/*
 * Usage:
 *   gcc -O2 experiment/pause_cycle_count.c -o /tmp/pause_cycle_count
 *   taskset -c 0 /tmp/pause_cycle_count
 *
 * Description:
 *   PAUSE 命令の実測サイクル数を測る最小プログラム。
 *   1e8 回 PAUSE を回して rdtscp で前後を挟み、平均サイクル数を出す。
 *   コア pin (taskset -c 0) 前提。turbo off / freq pinned だと安定した値が出る。
 *
 * Expected values (base clock, turbo off):
 *   Ivy Bridge   : ~10 cy
 *   Broadwell    : ~10 cy
 *   Skylake      : ~124 cy
 *   Sunny Cove   : ~39 cy
 *   Emerald Rapids: ~37 cy
 */
#include <stdio.h>
#include <stdint.h>
#include <x86intrin.h>

#define N 100000000ULL

int main(void) {
    unsigned dummy;
    uint64_t s = __rdtscp(&dummy);
    for (uint64_t i = 0; i < N; i++) __builtin_ia32_pause();
    uint64_t e = __rdtscp(&dummy);
    printf("PAUSE cycles = %.2f\n", (double)(e - s) / (double)N);
    return 0;
}
