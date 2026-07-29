#ifndef SPINLOCK_H
#define SPINLOCK_H

#include <pthread.h>
#include <stdint.h>

#define cpu_relax() asm volatile("rep; nop")

static inline uint64_t _rdtsc(void) {
    uint32_t lo, hi;
    asm volatile("rdtsc" : "=a"(lo), "=d"(hi));
    return ((uint64_t)hi << 32) | lo;
}

/* spinlock_record_handoff: implemented in thread.c */
extern void spinlock_record_handoff(uint64_t delta);

typedef struct {
    pthread_mutex_t mutex;
    uint64_t release_tsc; /* written by unlocker before unlock; read by next acquirer */
} spinlock_t;

#define SPINLOCK_INITIALIZER { PTHREAD_MUTEX_INITIALIZER, 0 }

/* MySQL (InnoDB) -like spinlock parameters.
 *
 * Pattern: [trylock -> cpu_relax x global_pause_per_round] x global_spin_rounds
 *          -> pthread_mutex_lock (futex fallback)
 *
 * global_spin_rounds     : number of (trylock + delay) cycles before falling
 *                          back to futex.  Equivalent to innodb_spin_wait_rounds.
 *                          Set via MEMCACHED_SPIN_ROUNDS at startup (default 30).
 *
 * global_pause_per_round : N PAUSEs executed between consecutive trylock calls.
 *                          Set via MEMCACHED_PAUSE_PER_ROUND at startup.
 *                          0 = no delay between trylocks.
 *
 * Contrast with the previous "1-pause-per-check" implementation where
 * global_pause_count controlled the total number of (trylock + 1 PAUSE)
 * iterations.  Here each check is separated by N PAUSEs, reducing CAS
 * frequency (and cache-coherence RFO traffic) for the same total spin time. */
extern int global_spin_rounds;
extern int global_pause_per_round;

static inline void spinlock_init(spinlock_t *sl) {
    pthread_mutex_init(&sl->mutex, NULL);
    sl->release_tsc = 0;
}

static inline void spinlock_lock(spinlock_t *sl) {
    for (int round = 0; round < global_spin_rounds; round++) {
        if (pthread_mutex_trylock(&sl->mutex) == 0) {
            spinlock_record_handoff(_rdtsc() - sl->release_tsc);
            return;
        }
        for (int p = 0; p < global_pause_per_round; p++) {
            cpu_relax();
        }
    }
    pthread_mutex_lock(&sl->mutex);
    spinlock_record_handoff(_rdtsc() - sl->release_tsc);
}

static inline int spinlock_trylock(spinlock_t *sl) {
    return pthread_mutex_trylock(&sl->mutex) == 0 ? 0 : -1;
}

static inline void spinlock_unlock(spinlock_t *sl) {
    /* release_tsc はunlock前に書く。pthread_mutex_unlockのリリースバリアにより
     * 次の獲得者には必ずこの値が見える。 */
    sl->release_tsc = _rdtsc();
    pthread_mutex_unlock(&sl->mutex);
}

#endif /* SPINLOCK_H */
