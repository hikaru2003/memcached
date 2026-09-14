# Smoke Test 手順書

**目的**: 本番実験を回す前に、各サーバで環境・バイナリ・スクリプトが正しく動作することを 10-20 分で確認する。

**所要時間**: 10-20 分 (全 6 種試す場合)

**方針**: 各 sweep を **N=0 のみ / DURATION=10s / RUNS=1** の最小構成で回し、出力が生成されて中身が妥当かを確認する。**QPS/latency の値の質はここでは問わない**。

---

## 前提

- サーバに ssh 済み、`~/Application/memcached` に居る
- 環境設定完了 (`bash experiment/setup_perf_env.sh` またはBIOS設定)
- 対象のバイナリがビルド済み (`./memcached_utdelay`, `./memcached_handoff_debug` 等)

---

## Step A. 環境チェック (30 秒)

```bash
echo "=== SMT ===";       cat /sys/devices/system/cpu/smt/active
echo "=== governor ==="; cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
echo "=== turbo ===";     cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || echo "N/A"
echo "=== paranoid ==="; cat /proc/sys/kernel/perf_event_paranoid
echo "=== TSC (base clk) ==="; awk '/cpu MHz/{print $NF; exit}' /proc/cpuinfo
```

- [ ] SMT active = **0** (off)
- [ ] governor = **performance**
- [ ] no_turbo = **1** (turbo off)
- [ ] perf_event_paranoid <= **1** (perf 使用可; futex sweep のみ **-1** 必要)
- [ ] cpu MHz が期待値付近 (Broadwell/Ice 2400, Emerald/Skylake ann 2100)

**NG の場合**: `sudo bash experiment/setup_perf_env.sh` を再実行。BIOS 側の設定 (turbo, C-state) は再起動が必要。

---

## Step B. PAUSE cycle 実測 (30 秒)

```bash
gcc -O2 experiment/pause_cycle_count.c -o /tmp/pause_cycle_count
taskset -c 0 /tmp/pause_cycle_count
```

- [ ] 期待値の ±20% 以内: Ivy ~10 / Broadwell ~10 / Skylake ~124 / Sunny Cove ~39 / Emerald ~37

**大幅にズレる場合**: cpufreq が固定されていない可能性。governor / no_turbo を再確認。

---

## Step C. mutilate 疎通確認 (30 秒)

```bash
./memcached -t 4 -m 128 -p 11222 -d
sleep 1
../mutilate/mutilate -s 127.0.0.1:11222 -r 1 -u 0.5 -T 1 -c 1 -t 3
pkill -f "memcached.*-p 11222"
```

- [ ] mutilate が QPS を報告 (数万〜十数万 QPS 程度)
- [ ] エラーなく完了

**NG の場合**: mutilate バイナリ位置 (`MUTILATE_BIN`) or ネットワーク疎通 (localhost) を確認。

---

## Step D. 各 sweep スクリプトの smoke run

**全て N=0 のみ / duration 10s / runs 1** で回す。それぞれ 1-2 分。

### D-1. utdelay_sweep (p999 版)

```bash
PAUSE_PER_ROUND_VALUES="0" WARMUP_SEC=10 DURATION=10 RUNS=1 \
  bash experiment/run_utdelay_sweep_p999.sh 2>&1 | tail -20
```

- [ ] `experiment/results/utdelay_p999_YYYYMMDD_HHMMSS/` 生成
- [ ] `summary.md`, `raw.csv`, `raw/` ディレクトリ存在
- [ ] `raw.csv` の N0 行に妥当な QPS (0 でない、数万以上) と r_p999 列に数値

確認:
```bash
LATEST=$(ls -td experiment/results/utdelay_p999_* | head -1)
head -5 "$LATEST/raw.csv"
```

### D-2. handoff_sweep

**バイナリ必要**: `./memcached_handoff_debug`

```bash
# handoff は memcached_handoff_debug バイナリを使う必要がある。
# experiment_env.sh が MEMCACHED_BIN=utdelay 用にしているので、都度上書き。
MEMCACHED_BIN=${MEMCACHED_HANDOFF_BIN:-./memcached_handoff_debug} \
  PAUSE_PER_ROUND_VALUES="0" WARMUP_SEC=10 DURATION=10 RUNS=1 \
  bash experiment/run_handoff_sweep.sh 2>&1 | tail -20
```

- [ ] `experiment/results/handoff_YYYYMMDD_HHMMSS/N0/` 生成
- [ ] `handoff_samples_thread{0..3}.bin` が非ゼロサイズで存在
- [ ] `stats.txt` に mean QPS

確認:
```bash
LATEST=$(ls -td experiment/results/handoff_* | head -1)
ls -la "$LATEST/N0/"
python3 experiment/extract_handoff_stats.py --dir "$LATEST" --tsc-mhz $(awk '/cpu MHz/{print int($NF); exit}' /proc/cpuinfo) 2>&1 | tail -5
```

- [ ] `handoff_summary.csv` が生成、p50/p99 に妥当な値 (数百 ns 〜 数 µs)

### D-3. cache_miss_sweep

```bash
PAUSE_PER_ROUND_VALUES="0" WARMUP_SEC=10 DURATION=10 RUNS=1 \
  bash experiment/run_cache_miss_sweep.sh 2>&1 | tail -20
```

- [ ] スクリプト冒頭に `[INFO] RFO event: <event名>` が出る
  - Broadwell / Ice / Skylake / Ivy: `offcore_requests.demand_rfo`
  - Emerald: `l2_rqsts.rfo_miss`
- [ ] `summary.csv` の `demand_rfo` 列が非ゼロ / 非 N/A

確認:
```bash
LATEST=$(ls -td experiment/results/cache_miss_* | head -1)
head -3 "$LATEST/summary.csv"
```

### D-4. futex_sweep (Phase 2 = ann 限定)

```bash
# 事前確認: perf_event_paranoid == -1 必要
sudo sh -c 'echo -1 > /proc/sys/kernel/perf_event_paranoid'

PAUSE_PER_ROUND_VALUES="0" WARMUP_SEC=10 DURATION=10 RUNS=1 \
  bash experiment/run_futex_sweep.sh 2>&1 | tail -20
```

- [ ] `summary.csv` の `futex_per_req` 列が数値 (N=0 で 0.5 前後、master で 1〜2 前後)

### D-5. unlock_sweep (ann 限定)

**バイナリ必要**: `./memcached_unlock_debug`

```bash
PAUSE_PER_ROUND_VALUES="0" WARMUP_SEC=10 DURATION=10 RUNS=1 \
  bash experiment/run_unlock_sweep.sh 2>&1 | tail -20
```

- [ ] `N0/unlock_samples_thread*.bin` が非ゼロ

確認:
```bash
LATEST=$(ls -td experiment/results/unlock_* | head -1)
python3 experiment/extract_unlock_stats.py --dir "$LATEST" --tsc-mhz $(awk '/cpu MHz/{print int($NF); exit}' /proc/cpuinfo) 2>&1 | tail -5
```

- [ ] `unlock_summary.csv` の p50/p99/mean_us が妥当

### D-6. hold_sweep (ann 限定)

**バイナリ必要**: `./memcached_hold_debug`

```bash
PAUSE_PER_ROUND_VALUES="0" WARMUP_SEC=10 DURATION=10 RUNS=1 \
  bash experiment/run_hold_sweep.sh 2>&1 | tail -20
```

- [ ] `N0/hold_samples_thread*.bin` が非ゼロ
- [ ] `extract_hold_stats.py` で p50/p99 が妥当

---

## Step E. push / collect の疎通 (2 分)

**cloudlab から ann への push テスト** (utdelay の smoke 結果を使用):

```bash
EXPERIMENT_TYPE=utdelay bash experiment/push_results.sh 2>&1 | tail
```

- [ ] git push 成功 (fork の該当ブランチが動く)

**ann 側で pull テスト**:
```bash
cd ~/Application/memcached
git fetch myfork
bash experiment/collect_results.sh 2>&1 | tail
```

- [ ] 該当アーキ dir に smoke run の結果が入る (例: `experiment/results/broadwell/utdelay_sweep_YYYYMMDD_HHMMSS/`)

---

## 全部 pass したら

smoke test で生成した結果は不要なので削除して本番へ:
```bash
# 各サーバでローカルの smoke 結果を削除
rm -rf experiment/results/utdelay_sweep_* experiment/results/handoff_* \
       experiment/results/cache_miss_* experiment/results/futex_* \
       experiment/results/unlock_* experiment/results/hold_*
```

ann 側で collect した smoke 結果も同様に削除。

**本番実行に進む**: `CURRENT_EXPERIMENTS.md` の Phase 1 / Phase 2 のチェックボックスを埋めていく。

---

## トラブルシューティング

| 症状 | 原因候補 | 対処 |
|---|---|---|
| `[ERROR] SMT is ON` | SMT 有効 | `sudo bash experiment/setup_perf_env.sh` |
| `[ERROR] governor=powersave` | governor 設定不足 | 同上 |
| PAUSE cycle が大幅ズレ | cpufreq 未固定 or turbo on | governor / no_turbo 確認、BIOS 見直し |
| perf stat がエラー | paranoid > 1 | `sudo sh -c 'echo -1 > /proc/sys/kernel/perf_event_paranoid'` |
| `demand_rfo` が全て 0 or N/A | イベント未対応 (Emerald 想定外) | `[INFO] RFO event:` の行を確認、`RFO_EVENT=l2_rqsts.rfo_miss` を強制指定 |
| `handoff_samples_thread*.bin` が空 | debug バイナリ違い | `git log --oneline -1` で `debug/handoff-latency` HEAD 確認 |
| mutilate に接続できない | port 使用中 | `pkill memcached`、`ss -ltnp | grep 11222` で確認 |
| push_results.sh が fail | git remote 未設定 | `git remote -v` で `myfork` 確認 |
