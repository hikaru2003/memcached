# cloudlab 実行手順 (コピペ用)

**用途**: cloudlab で 1 サーバ借りて Phase 1 (utdelay + handoff + cache_miss) を回すまでの手順。全コマンドコピペで動くようになっている。

**関連ドキュメント**:
- 実験計画全体: [CURRENT_EXPERIMENTS.md](CURRENT_EXPERIMENTS.md)
- Smoke test 詳細: [SMOKE_TEST.md](SMOKE_TEST.md)

**所要時間目安**: 予約 5 分 + セットアップ 15 分 + smoke 15 分 + 本番 35 時間 (utdelay 21h + handoff 7h + cache_miss 7h)

---

## Step 1. cloudlab でノード予約

1. https://cloudlab.us にログイン
2. **Experiments → Start Experiment**
3. **Profile**: `hikaru2003/memcached-pause-sweep` (v2 profile)
   - 未登録の場合: **Create Profile** で `experiment/cloudlab_profile_v2.py` を貼り付けて保存
4. **Parameters** で以下を選択:
   - **最初は**: `Broadwell (xl170)` @ Utah
   - **次からは**: Ivy Bridge (c8220) / Skylake (c220g5) / Sunny Cove (sm110p) / Emerald (c6620)
5. **Next → Finalize → Start**
6. Cluster: 選んだアーキ対応のクラスタ (xl170/c6620=Utah, c8220=Clemson, c220g5/sm110p=Wisconsin)
7. ステータスが **Ready** になるまで待つ (2-3 分)

---

## Step 2. SSH 接続 + セットアップ完了待ち

cloudlab の Experiment 画面から SSH コマンドをコピー。**`-A` 必須** (git push で必要):

```bash
ssh -A Morisaki@<hostname>.<cluster>.cloudlab.us
```

セットアップ進捗を眺める (~15 分で完了):

```bash
tail -f /tmp/setup_memcached.log
```

**完了サイン** — 以下が出たら Ctrl+C で抜ける:
```
============================================================
 Setup complete!  (arch: <arch_name>)
============================================================
```

---

## Step 3. 環境設定

```bash
sudo bash /users/Morisaki/memcached/experiment/setup_perf_env.sh
```

**期待出力**: `[OK] SMT off`, `[OK] governor=performance`, `[OK] turbo off` 等の OK 行のみ。ERROR が出たら止めて相談。

---

## Step 4. 作業ディレクトリに移動 + env 読み込み

```bash
cd /users/Morisaki/memcached
source ~/experiment_env.sh
```

**確認**:
```bash
echo "MC_DIR=$MC_DIR  MEMCACHED_BIN=$MEMCACHED_BIN"
echo "MUTILATE_BIN=$MUTILATE_BIN"
```
バイナリパスが `/users/Morisaki/...` で始まっていれば OK。

---

## Step 5. Smoke test (10-20 分)

### Step 5-A. 環境チェック

```bash
echo "=== SMT ===";       cat /sys/devices/system/cpu/smt/active
echo "=== governor ==="; cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
echo "=== turbo ===";     cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || echo "N/A"
echo "=== paranoid ==="; cat /proc/sys/kernel/perf_event_paranoid
echo "=== TSC ==="; awk '/cpu MHz/{print $NF; exit}' /proc/cpuinfo
```

**期待**: SMT=**0** / governor=**performance** / no_turbo=**1** / paranoid<=**1** / MHz が期待値付近

### Step 5-B. PAUSE cycle 実測

```bash
if [ ! -f ~/simple_mysql/pause_cycle_count.c ]; then
  mkdir -p ~/simple_mysql
  cat > ~/simple_mysql/pause_cycle_count.c << 'EOF'
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
EOF
fi
gcc -O2 ~/simple_mysql/pause_cycle_count.c -o /tmp/pause_cycle_count
taskset -c 0 /tmp/pause_cycle_count
```

**期待**: Ivy ~10 / Broadwell ~10 / Skylake ~124 / Sunny Cove ~39 / Emerald ~37

### Step 5-C. utdelay smoke (~2 分)

```bash
PAUSE_PER_ROUND_VALUES="0" WARMUP_SEC=10 DURATION=10 RUNS=1 \
  bash experiment/run_utdelay_sweep_p999.sh 2>&1 | tail -20
```

確認:
```bash
LATEST=$(ls -td experiment/results/utdelay_p999_* | head -1)
head -3 "$LATEST/raw.csv"
```
- N0 行に QPS (数万〜) と r_p999_us が数値で入っている

### Step 5-D. handoff smoke (~2 分)

```bash
# handoff は memcached_handoff_debug バイナリを使う。
# experiment_env.sh の MEMCACHED_BIN (utdelay 用) を都度上書き。
MEMCACHED_BIN="$MEMCACHED_HANDOFF_BIN" \
  PAUSE_PER_ROUND_VALUES="0" WARMUP_SEC=10 DURATION=10 RUNS=1 \
  bash experiment/run_handoff_sweep.sh 2>&1 | tail -20
```

確認:
```bash
LATEST=$(ls -td experiment/results/handoff_* | head -1)
ls -la "$LATEST/N0/" | grep bin
TSC=$(awk '/cpu MHz/{print int($NF); exit}' /proc/cpuinfo)
python3 experiment/extract_handoff_stats.py --dir "$LATEST" --tsc-mhz "$TSC" 2>&1 | tail -5
head -3 "$LATEST/handoff_summary.csv"
```
- `handoff_samples_thread{0..3}.bin` が非ゼロサイズ
- `handoff_summary.csv` に p50/p99/p999 の妥当な数値

### Step 5-E. cache_miss smoke (~2 分)

```bash
PAUSE_PER_ROUND_VALUES="0" WARMUP_SEC=10 DURATION=10 RUNS=1 \
  bash experiment/run_cache_miss_sweep.sh 2>&1 | tee /tmp/cm_smoke.log | tail -20
grep "^\[INFO\] RFO event" /tmp/cm_smoke.log
```

- **`[INFO] RFO event: offcore_requests.demand_rfo`** が出る (Emerald のみ `l2_rqsts.rfo_miss`)

確認:
```bash
LATEST=$(ls -td experiment/results/cache_miss_* | head -1)
head -3 "$LATEST/summary.csv"
```
- `demand_rfo` 列が非ゼロ

### Step 5-F. push 疎通確認

```bash
EXPERIMENT_TYPE=utdelay bash experiment/push_results.sh 2>&1 | tail
```
- git push 成功
- myfork に `experiment/results/<arch>-utdelay-YYYYMMDD` ブランチができる

**GitHub で確認**: https://github.com/hikaru2003/memcached/branches → 該当ブランチ存在

### Step 5-G. smoke 結果を削除

```bash
rm -rf experiment/results/utdelay_p999_* experiment/results/handoff_* experiment/results/cache_miss_*
```

**smoke で作った push ブランチも myfork 側で削除** (option、残しても実害ない):
```bash
DATE=$(date +%Y%m%d); ARCH=$(source ~/experiment_env.sh 2>/dev/null; ls /users/Morisaki/memcached/experiment/results/ 2>/dev/null | head -1)
# GitHub UI から手動削除するのが確実
```

---

## Step 6. 本番: utdelay_sweep (~21 時間)

`tmux` で起動 (SSH 切れても継続):

```bash
tmux new -s utdelay
```

tmux セッション内:
```bash
source ~/experiment_env.sh
cd /users/Morisaki/memcached
bash experiment/run_utdelay_sweep_p999.sh 2>&1 | tee /tmp/utdelay.log
```

`Ctrl+B, D` で detach → SSH 切って OK。

**進捗確認** (別 SSH セッションから):
```bash
tail -f /tmp/utdelay.log
```

**再接続**:
```bash
tmux attach -t utdelay
```

### Step 6 完了後の確認

```bash
LATEST=$(ls -td experiment/results/utdelay_p999_* | head -1)
cat "$LATEST/summary.md"
```

**チェック項目**:
- [ ] 40 個の N 値すべてが行にある
- [ ] cv% (CV) が全体的に **< 5%**
- [ ] peak N (mean_QPS 最大) がアーキ期待値付近:
  - Broadwell: N ≈ 40-50
  - Skylake: N ≈ 5
  - Sunny Cove: N ≈ 15
  - Emerald: N ≈ 30
  - Ivy Bridge: N ≈ 40-50

### push

```bash
EXPERIMENT_TYPE=utdelay bash experiment/push_results.sh
```

---

## Step 7. 本番: handoff_sweep (~7 時間)

```bash
tmux new -s handoff
```

tmux 内:
```bash
source ~/experiment_env.sh
cd /users/Morisaki/memcached
export MEMCACHED_BIN="$MEMCACHED_HANDOFF_BIN"   # handoff 用バイナリに切替
bash experiment/run_handoff_sweep.sh 2>&1 | tee /tmp/handoff.log
```

### 完了後

```bash
LATEST=$(ls -td experiment/results/handoff_* | head -1)
TSC=$(awk '/cpu MHz/{print int($NF); exit}' /proc/cpuinfo)
python3 experiment/extract_handoff_stats.py --dir "$LATEST" --tsc-mhz "$TSC"
cat "$LATEST/handoff_summary.csv" | head -5
```

**チェック項目**:
- [ ] 40 個の N 値の handoff_summary.csv が出る
- [ ] p50 の最小値がアーキ期待値付近 (N=10-25 で min)

### push

```bash
EXPERIMENT_TYPE=handoff bash experiment/push_results.sh
```

---

## Step 8. 本番: cache_miss_sweep (~7 時間)

```bash
tmux new -s cache_miss
```

tmux 内:
```bash
source ~/experiment_env.sh
cd /users/Morisaki/memcached
unset MEMCACHED_BIN                              # utdelay バイナリに戻す (デフォルト)
bash experiment/run_cache_miss_sweep.sh 2>&1 | tee /tmp/cache_miss.log
```

### 完了後

```bash
LATEST=$(ls -td experiment/results/cache_miss_* | head -1)
head -5 "$LATEST/summary.csv"
```

**チェック項目**:
- [ ] `demand_rfo` 列が全 N で非ゼロ
- [ ] RFO/req が N と共にほぼ単調減少

### push

```bash
EXPERIMENT_TYPE=cache_miss bash experiment/push_results.sh
```

---

## Step 9. サーバ返却前チェックリスト

**myfork リモートで 3 ブランチ確認**:

```bash
git ls-remote myfork | grep "$(date +%Y%m%d)"
```
以下 3 本が存在するはず (`<arch>` は Ivy/Broadwell/Skylake/Ice/Emerald のいずれか):
- `experiment/results/<arch>-utdelay-YYYYMMDD`
- `experiment/results/<arch>-handoff-YYYYMMDD`
- `experiment/results/<arch>-cache_miss-YYYYMMDD`

- [ ] utdelay 完了 + push 済み
- [ ] handoff 完了 + push 済み
- [ ] cache_miss 完了 + push 済み
- [ ] 3 ブランチが GitHub 上にある

**サーバ返却**: cloudlab の Experiment 画面 → **Terminate**

---

## Step 10. ann 側で結果収集

**ann に戻ってから**:
```bash
cd ~/Application/memcached
git fetch myfork
bash experiment/collect_results.sh
```

**確認**:
```bash
ARCH=broadwell   # 実施したアーキ名
ls experiment/results/$ARCH/
```
- 該当アーキ dir に utdelay_p999_* / handoff_* / cache_miss_* の 3 dir が入っていれば OK

---

## 次のサーバへ

同じ Step 1-9 を次のアーキで繰り返す:
1. xl170 (Broadwell) ← 最初
2. c8220 (Ivy Bridge)
3. c220g5 (Skylake)
4. sm110p (Sunny Cove / Ice Lake)
5. c6620 (Emerald Rapids)

---

## トラブル時

- **セットアップログ**: `/tmp/setup_memcached.log`
- **各 tmux セッションのログ**: `/tmp/utdelay.log`, `/tmp/handoff.log`, `/tmp/cache_miss.log`
- **その他の症状 → 対処**: [SMOKE_TEST.md](SMOKE_TEST.md) 末尾のトラブルシューティング表を参照
