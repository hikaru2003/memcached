# 実験再測定プラン (本採用データ, 2026-09-10 更新)

## 方針

- **本採用データとして正確性を優先** — 実験時間が長くなっても構わない
- **1 コマンドで全て回さない** — 各実験ごとに結果を確認してから次へ進む
- 過去の結果は `experiment/results/archive/20260910/` に退避済み
- 新規結果は `experiment/results/<arch>/<type>_YYYYMMDD_HHMMSS/` に保存
- **各 sweep スクリプトのデフォルトを本プランと一致させ済** (下の N 値・時間表を参照) → 通常は env var なしで `bash experiment/run_*.sh` で OK
- utdelay は **`run_utdelay_sweep_p999.sh`** を採用 (p50/p999 込みで `mutilate_p999` 使用、push_results.sh との互換性あり)
- cache_miss スクリプトは `perf list` から RFO イベントを自動判別 (Emerald は `l2_rqsts.rfo_miss`)

---

## N 値 (全実験共通 40 点、低 N 域を密に)

```
0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 20 22 24 26 28 30 33 36 40 45 50 55 60 70 80 90 100 125 150 175 200
```

- 0-18: 全整数 (peak 探索精度、Skylake peak≈5, Sunny Cove≈15, Emerald≈30 帯を細かく)
- 20-50: 2-5 刻み (Broadwell peak≈45 帯をカバー)
- 55-200: 減衰域

## 時間パラメータ (全実験、正確性重視)

| 実験 | warmup | duration | runs | 総時間/N | 40 N 合計 |
|---|---|---|---|---|---|
| utdelay | 120s | 60s | **30** | 1920s | 21.3h |
| handoff | 60s | 60s | 10 | 660s | 7.3h |
| cache_miss | 60s | 60s | 10 | 660s | 7.3h |
| unlock (ann) | 60s | 60s | 10 | 660s | 7.3h |
| hold (ann) | 60s | 60s | 10 | 660s | 7.3h |
| futex (ann) | 60s | 60s | 10 | 660s | 7.3h |

**サーバ別合計**:
- cloudlab 各サーバ (Ivy / Broadwell / Skylake / Sunny Cove / Emerald): utdelay + handoff + cache_miss = **~36 時間 / サーバ**
- ann (Skylake): Phase 1 (36h) + Phase 2 (unlock + hold_mixed + hold_get100 + futex = 4×7h = 28h) = **~64 時間**
- **全サーバ合計**: cloudlab 5 × 36h + ann 64h = **244 時間 (約 10 日分の実行時間)**

cloudlab の予約は 24h 単位で複数回に分割する必要がある。

---

## サーバ一覧

| サーバ | ノード | アーキ | ベースクロック | 実施実験 |
|---|---|---|---|---|
| c8220 系 (cloudlab) | Xeon E5-2650v2 相当 | Ivy Bridge | 2.6 GHz | Phase 1 (utdelay + handoff + cache_miss) |
| xl170 (cloudlab) | E5-2640 v4 | Broadwell | 2.4 GHz | Phase 1 |
| c220g5 (cloudlab) | Silver 4114 | Skylake | 2.2 GHz | Phase 1 |
| sm110 (cloudlab) | Silver 4314 | Sunny Cove (Ice Lake) | 2.4 GHz | Phase 1 |
| c6620 (cloudlab) | Gold 5512U | Emerald Rapids | 2.1 GHz | Phase 1 |
| **ann (研究室)** | Silver 4110 | Skylake | 2.1 GHz | Phase 1 + **Phase 2 (unlock + hold + futex)** |

**Skylake 系の位置付け**:
- **cloudlab c220g5 (Silver 4114)**: 他アーキとの比較用 (同一 cloudlab 環境で条件揃え)。**Phase 1 は cloudlab を主データとする**
- **ann (Silver 4110)**: Phase 2 (unlock/hold/futex) の debug binary が既に設定済。**Phase 2 のメカニズム解析はこちらで**
- 両者は Skylake マイクロアーキ的にはほぼ同じ (Silver 4110 vs 4114) だが、環境設定・周波数が異なるので Phase 1 の QPS 比較には cloudlab 側を採用。ann は Phase 2 の内部指標のみ。

**Ivy Bridge を追加する目的**: 世代軸 (Ivy → Broadwell → Skylake → Sunny Cove → Emerald) を揃えることで、PAUSE cycle 数の世代変化と QPS 山形の対応をより明確に示す。

---

## 共通環境準備 (各サーバで最初に1回)

### Step 0. PAUSE cycle 実測

```bash
gcc -O2 ~/simple_mysql/pause_cycle_count.c -o /tmp/pause_cycle_count
taskset -c 0 /tmp/pause_cycle_count
```

期待値: Ivy Bridge ~10cy / Broadwell ~10cy / Skylake ~124cy / Sunny Cove ~39cy / Emerald ~37cy
(Ivy Bridge は Broadwell と同じ短 PAUSE 世代、Skylake で微アーキが変わって長 PAUSE 化)

### Step 1. 環境設定

**cloudlab**:
```bash
sudo bash experiment/setup_perf_env.sh
```
(SMT off、intel_pstate passive、governor=performance、base clock 固定、turbo off)

**ann**: BIOS 設定済み (turbo off / Uncore max / C-state off / SMT off)

### Step 2. バイナリビルド

Phase 1 用 (utdelay + cache_miss):
```bash
git checkout experiment/mysql-like-utdelay
make && cp memcached memcached_utdelay
```

handoff 用:
```bash
git checkout debug/handoff-latency
make && cp memcached memcached_handoff_debug
```

Phase 2 用 (ann 限定):
```bash
git checkout debug/unlock-latency && make && cp memcached memcached_unlock_debug
git checkout debug/hold-time-v2   && make && cp memcached memcached_hold_debug
```

futex は utdelay バイナリで測定可能 (perf trace で拾う)。

---

## Phase 1: 全 6 アーキ共通

### 実験 1-0: cloudlab Ivy Bridge (c8220 系)

- [ ] **Step 0**: PAUSE cycle 実測 (~10cy 期待)
- [ ] **Step 1**: `sudo bash experiment/setup_perf_env.sh`
- [ ] **Step 2**: memcached_utdelay, memcached_handoff_debug ビルド
- [ ] **1-0-a**: utdelay_sweep (21h)
- [ ] **結果確認**
- [ ] **1-0-b**: handoff_sweep (7h)
- [ ] **結果確認**
- [ ] **1-0-c**: cache_miss_sweep (7h)
- [ ] **結果確認**

### 実験 1-1: xl170 (Broadwell)

- [ ] **Step 0**: PAUSE cycle 実測 (~10cy 期待)
- [ ] **Step 1**: `sudo bash experiment/setup_perf_env.sh`
- [ ] **Step 2**: memcached_utdelay, memcached_handoff_debug ビルド
- [ ] **1-1-a**: utdelay_sweep (21h) — `bash experiment/run_utdelay_sweep_p999.sh` (p999 データ込み) / push: `EXPERIMENT_TYPE=utdelay bash experiment/push_results.sh`
- [ ] **結果確認**: peak N と mean QPS の CV を確認 → OK なら次へ
- [ ] **1-1-b**: handoff_sweep (7h) — `bash experiment/run_handoff_sweep.sh` / push: `EXPERIMENT_TYPE=handoff bash experiment/push_results.sh`
- [ ] **結果確認**: p50 の U 字型を確認 (min N の位置)
- [ ] **1-1-c**: cache_miss_sweep (7h) — `bash experiment/run_cache_miss_sweep.sh` / push: `EXPERIMENT_TYPE=cache_miss bash experiment/push_results.sh`
- [ ] **結果確認**: RFO/req が N と共に減少していることを確認

### 実験 1-2: sm110 (Sunny Cove / Ice Lake)

- [ ] **Step 0**: PAUSE cycle 実測 (~39cy 期待)
- [ ] **Step 1**: `sudo bash experiment/setup_perf_env.sh`
- [ ] **Step 2**: memcached_utdelay, memcached_handoff_debug ビルド
- [ ] **1-2-a**: utdelay_sweep (21h) — 上記 1-1-a と同じコマンド
- [ ] **結果確認**
- [ ] **1-2-b**: handoff_sweep (7h)
- [ ] **結果確認**
- [ ] **1-2-c**: cache_miss_sweep (7h)
- [ ] **結果確認**

### 実験 1-3: c6620 (Emerald Rapids)

- [ ] **Step 0**: PAUSE cycle 実測 (~37cy 期待)
- [ ] **Step 1**: `sudo bash experiment/setup_perf_env.sh`
- [ ] **Step 2**: memcached_utdelay, memcached_handoff_debug ビルド
- [ ] **1-3-a**: utdelay_sweep (21h)
- [ ] **結果確認**
- [ ] **1-3-b**: handoff_sweep (7h)
- [ ] **結果確認**
- [ ] **1-3-c**: cache_miss_sweep (7h) — スクリプトが `perf list` で自動判別 (Emerald は `l2_rqsts.rfo_miss` にフォールバック)
- [ ] **結果確認**

### 実験 1-4: c220g5 (cloudlab Skylake, Silver 4114) — Phase 1 主データ

- [ ] **Step 0**: PAUSE cycle 実測 (~124cy 期待)
- [ ] **Step 1**: `sudo bash experiment/setup_perf_env.sh`
- [ ] **Step 2**: memcached_utdelay, memcached_handoff_debug ビルド
- [ ] **1-4-a**: utdelay_sweep (21h)
- [ ] **結果確認**
- [ ] **1-4-b**: handoff_sweep (7h)
- [ ] **結果確認**
- [ ] **1-4-c**: cache_miss_sweep (7h)
- [ ] **結果確認**

### 実験 1-5: ann (Skylake, Silver 4110) — Phase 2 主データ + 参考 Phase 1

- [ ] **Step 0**: PAUSE cycle 実測 (~124cy 期待)
- [ ] **Step 1**: BIOS 済み — スキップ
- [ ] **Step 2**: memcached_utdelay, memcached_handoff_debug ビルド
- [ ] **1-5-a**: utdelay_sweep (21h) — cloudlab-skylake との差分検証用 (優先度低)
- [ ] **結果確認**
- [ ] **1-5-b**: handoff_sweep (7h) — Phase 2 の Stage 3 分析で使うので必須
- [ ] **結果確認**
- [ ] **1-5-c**: cache_miss_sweep (7h) — Phase 2 の RFO 補助データ
- [ ] **結果確認**

---

## Phase 2: Skylake ann 限定 (メカニズム解明)

- [ ] **Step 2-add**: memcached_unlock_debug, memcached_hold_debug ビルド
- [ ] **2-a**: unlock_sweep (7h) — `bash experiment/run_unlock_sweep.sh`
- [ ] **結果確認**: unlock latency mean が N と共に単調減少していることを確認
- [ ] **2-b**: hold_sweep (SET+GET 50/50 mixed) (7h) — `bash experiment/run_hold_sweep.sh`
- [ ] **結果確認**: CS 長分布 (p50, mean) を確認
- [ ] **2-c**: hold_sweep (GET 100%) (7h) — `UPDATE_RATIO=0.0 bash experiment/run_hold_sweep.sh` (SET 割合のみ上書き)
- [ ] **結果確認**: item_lock 単体競合の CS 長を確認
- [ ] **2-d**: futex_sweep (7h) — `bash experiment/run_futex_sweep.sh`
- [ ] **結果確認**: futex/req が N と共に減少 (N=1 で激減) を確認

---

## Phase 3: 全結果の収集と可視化

- [ ] cloudlab 5 サーバから ann サーバへ結果を pull
  ```bash
  cd ~/Application/memcached && git fetch myfork && bash experiment/collect_results.sh
  ```
- [ ] 各アーキの結果構造を確認
  ```bash
  for a in ivybridge broadwell skylake icelake emeraldrapids skylake_ann; do echo "== $a =="; ls experiment/results/$a/; done
  ```
- [ ] グラフ再生成 (plots/v4/ に出力)
  ```bash
  OUTPUT_DIR=experiment/results/plots/v4 python3 experiment/plot_handoff_comparison.py
  OUTPUT_DIR=experiment/results/plots/v4 python3 experiment/plot_cache_miss_comparison.py
  OUTPUT_DIR=experiment/results/plots/v4 python3 experiment/plot_futex_comparison.py
  # ann 単独系:
  python3 experiment/plot_unlock_sweep.py --dir experiment/results/skylake_ann/unlock_<latest>/ --outdir experiment/results/plots/v4
  python3 experiment/plot_futex_rfo_ann.py  # FUTEX_CSV / RFO_CSV パスを最新に更新して実行
  ```
- [ ] research_summary.html の数値・グラフを最新に更新

---

## 実行順序の推奨

1. **cloudlab 5 サーバ順次** (1 サーバ 36h、各 2 泊 3 日相当)
   - 順: c8220 (Ivy) → xl170 (Broadwell) → c220g5 (Skylake) → sm110 (Sunny Cove) → c6620 (Emerald)
   - サーバ返却前に必ず push
2. **ann 継続実行** (合計 64h、分割で 3-4 泊)
   - 日中: Phase 2 (unlock 7h、hold_mixed 7h)
   - 夜間: Phase 2 (hold_get100 7h、futex 7h)
   - 追加: Phase 1 (handoff 7h、cache_miss 7h) を優先実施 (utdelay 21h は cloudlab-skylake で取れたら省略可)
3. **Phase 3 の集計・可視化**

---

## push / collect の統一手順

各サーバで実験完了後:
```bash
EXPERIMENT_TYPE=utdelay    bash experiment/push_results.sh
EXPERIMENT_TYPE=handoff    bash experiment/push_results.sh
EXPERIMENT_TYPE=cache_miss bash experiment/push_results.sh
# ann のみ:
EXPERIMENT_TYPE=unlock bash experiment/push_results.sh
EXPERIMENT_TYPE=hold   bash experiment/push_results.sh
EXPERIMENT_TYPE=futex  bash experiment/push_results.sh
```

ann サーバ (母艦) で全結果収集:
```bash
cd ~/Application/memcached
git fetch myfork
bash experiment/collect_results.sh
```

---

## 参照

- 実験スクリプト: `experiment/run_{utdelay,handoff,cache_miss,unlock,hold,futex}_sweep.sh`
- 環境設定: `experiment/setup_perf_env.sh`
- push: `experiment/push_results.sh`
- collect: `experiment/collect_results.sh`
- 中間まとめ: `experiment/docs/research_summary.html`
- 過去データ: `experiment/results/archive/20260910/`

Notion:
- [ann サーバ環境設定](https://app.notion.com/p/3d43263a102881bb97bcd4e0fcba48c5)
- [memcached コード解説](https://app.notion.com/p/3d73263a102880188b29cf6d8f1e441d)
- [cache miss / RFO 実験ページ](https://app.notion.com/p/3973263a1028803f9b36fe82438fbce5)
- [全体振り返り (2026-08-31)](https://app.notion.com/p/3cd3263a1028812a8201f892b9585e34)
