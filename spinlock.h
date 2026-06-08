#ifndef SPINLOCK_H
#define SPINLOCK_H

#include <pthread.h>

#define cpu_relax() asm volatile("rep; nop")

typedef struct {
    pthread_mutex_t mutex;
} spinlock_t;

#define SPINLOCK_INITIALIZER { PTHREAD_MUTEX_INITIALIZER }

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
}

static inline void spinlock_lock(spinlock_t *sl) {
    for (int round = 0; round < global_spin_rounds; round++) {
        if (pthread_mutex_trylock(&sl->mutex) == 0)
            return;
        for (int p = 0; p < global_pause_per_round; p++) {
            cpu_relax();
        }
    }
    pthread_mutex_lock(&sl->mutex);
}

static inline int spinlock_trylock(spinlock_t *sl) {
    return pthread_mutex_trylock(&sl->mutex) == 0 ? 0 : -1;
}

static inline void spinlock_unlock(spinlock_t *sl) {
    pthread_mutex_unlock(&sl->mutex);
}

#endif /* SPINLOCK_H */
