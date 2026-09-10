void spinlock_lock(lock) {
    for (round = 0; round < spin_rounds; round++) {  // 30ラウンド固定
        if (trylock(lock) == SUCCESS)
            return;
        for (p = 0; p < N; p++)
            PAUSE();               // PAUSE命令 × N回
    }
    OS_wait(lock);                 // futex fallback
}