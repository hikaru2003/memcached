# memcached 実験リポジトリ

hikaru2003/memcached の fork。memcached の item_lock スピンロック最適化実験を行っている。

## 研究目的

pthread_mutex_lock のブロッキングコストを、スピンロック（trylock + PAUSE命令）で削減できるかを検証する。MySQL InnoDB の ut_delay パターンを参考に実装し、アーキテクチャごとの最適 PAUSE 回数を実測で求める。

## ブランチ構成

| ブランチ | 内容 |
|---|---|
| `experiment/mysql-like-utdelay` | **メイン実験ブランチ**。CloudLab 実験の clone 元。`[PAUSE×N → trylock] × SPIN_ROUNDS` |
| `experiment/pause-spinlock` | 別実装。`[trylock → PAUSE×1] × N` |
| `debug/futex-count` | futex 呼び出し回数計測用 |
| `debug/hold-time` | item_lock 保持時間計測用（rdtsc） |
| `master` | upstream memcached（baseline 比較用） |

スクリプト変更は両ブランチに cherry-pick で同期する（`experiment/mysql-like-utdelay` が CloudLab の fetch 元）。

## スピンロック実装

### mysql-like-utdelay ブランチ

```c
// memcached.h
// 環境変数: MEMCACHED_PAUSE_PER_ROUND=N, MEMCACHED_SPIN_ROUNDS=R
for (int r = 0; r < spin_rounds; r++) {
    for (int i = 0; i < pause_per_round; i++) cpu_relax(); // PAUSE×N
    if (trylock()) return;
}
pthread_mutex_lock();
```

### pause-spinlock ブランチ

```c
// memcached.h
// 環境変数: MEMCACHED_PAUSE_COUNT=N
for (int i = 0; i < pause_count; i++) {
    if (trylock()) return;
    cpu_relax(); // PAUSE×1
}
pthread_mutex_lock();
```

## バイナリ配置（annサーバ / `~/Application/memcached/`）

| ファイル | 内容 |
|---|---|
| `./memcached` | pause-spinlock ブランチビルド |
| `./memcached_utdelay` | mysql-like-utdelay ブランチビルド |
| `./memcached_master` | master ブランチビルド（baseline） |

## 実験スクリプト

| スクリプト | 用途 |
|---|---|
| `experiment/setup_cloudlab.sh` | CloudLab 新規サーバのセットアップ（clone/build/mutilate） |
| `experiment/setup_perf_env.sh` | 実験前 CPU 環境統一（SMT off / performance governor / turbo off） |
| `experiment/run_utdelay_sweep.sh` | mysql-like-utdelay 用 PAUSE_PER_ROUND スイープ |
| `experiment/run_pause_sweep.sh` | pause-spinlock 用 PAUSE_COUNT スイープ |
| `experiment/push_results.sh` | 結果を GitHub にpush |
| `experiment/collect_results.sh` | 全アーキの結果をこのサーバに収集 |
| `experiment/plot_arch_comparison.py` | アーキ比較グラフ生成（QPS/正規化/レイテンシ） |

## 実験パラメータ（統一値）

```
MEMCACHED_BIN      = ./memcached_utdelay
MEMCACHED_MASTER_BIN = ./memcached_master
MC_THREADS=4  MC_CPUS=0-3
MUT_THREADS=4  MUT_CONNS=1  DEPTH=32  RECORDS=1  UPDATE_RATIO=0.5
WARMUP_SEC=300  DURATION=60  RUNS=20  SPIN_ROUNDS=30
PAUSE_PER_ROUND_VALUES="0 1 2 3 4 5 6 7 8 9 10 15 20 30 50 80 100 150 200"
```

## annサーバでの実験実行

```bash
cd ~/Application/memcached

# utdelay ブランチの実験
MEMCACHED_BIN=./memcached_utdelay bash experiment/run_utdelay_sweep.sh

# pause-spinlock ブランチの実験
bash experiment/run_pause_sweep.sh
```

## CloudLab での実験フロー

```bash
# 1. 新規サーバ（ssh -A でログイン）
bash <(curl -fsSL https://raw.githubusercontent.com/hikaru2003/memcached/experiment/mysql-like-utdelay/experiment/setup_cloudlab.sh)

# 2. CPU 環境統一（実験前に必ず実施）
sudo bash ~/Application/memcached/experiment/setup_perf_env.sh
# 確認: smt_active=0 / governor=performance / turbo_off=1

# 3. 実験
bash ~/run_utdelay_experiment.sh

# 4. 結果を push（ssh -A が必要）
cd ~/Application/memcached && bash experiment/push_results.sh
# ARCH_NAME を手動指定する場合: ARCH_NAME=skylake bash experiment/push_results.sh
```

## 結果収集・グラフ生成（このサーバ）

```bash
cd ~/Application/memcached
git fetch myfork
bash experiment/collect_results.sh
python3 experiment/plot_arch_comparison.py
# 出力: experiment/results/arch_comparison_*.png
```

## CPU 環境設定（annサーバ基準）

| 項目 | 設定値 | 理由 |
|---|---|---|
| SMT | off | HT によるリソース競合排除 |
| governor | performance | 周波数変動排除 |
| Turbo Boost | off (no_turbo=1) | クロック非決定性排除 |

## 計測済みアーキテクチャ PAUSE レイテンシ

| アーキ | ハードウェア | PAUSE (cyc) | 最適 N (実測) |
|---|---|---|---|
| Ivy Bridge | c8220 / Xeon E5-2650 v2 | ~15 | 未計測 |
| Broadwell | xl170 / Xeon E5-2640 v4 | ~12 | ~50-100（不明瞭） |
| Skylake | c220g5 / Xeon Silver 4114 | ~142 | 4 |
| Ice Lake | sm110 / Xeon Gold 6338 | ~39 | 未計測 |
| Emerald Rapids | c6620 / Xeon Gold 6554S | ~37 | ~20-30 |

## remotes

| remote | URL |
|---|---|
| `origin` | memcached/memcached（upstream） |
| `myfork` | hikaru2003/memcached（実験用 fork） |

結果 push 先は `myfork`。`ssh -A` による agent forwarding で認証する。
