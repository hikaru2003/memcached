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

## Phase 2: 全アーキで unlock / hold / futex (メカニズム解明、~35h/サーバ)

**方針**: mechanism 分析データを全アーキで揃える (unlock latency も CS 長もアーキで変わる想定)。
setup_cloudlab.sh がすでに memcached_unlock_debug と memcached_hold_debug をビルドするので、追加ビルド不要。

**各 cloudlab サーバでの Phase 2 実験** (各実験 ~7h):

- [ ] **Pre**: `sudo sh -c 'echo -1 > /proc/sys/kernel/perf_event_paranoid'` (futex tracepoint 用)
- [ ] **2-a**: `unlock_sweep` — `MEMCACHED_BIN=$MEMCACHED_UNLOCK_BIN bash experiment/run_unlock_sweep.sh`
- [ ] **結果確認**: unlock latency mean が N と共に単調減少しているか
- [ ] **push**: `EXPERIMENT_TYPE=unlock bash experiment/push_results.sh`
- [ ] **2-b**: `hold_sweep (mixed 50/50)` — `MEMCACHED_BIN=$MEMCACHED_HOLD_BIN bash experiment/run_hold_sweep.sh`
- [ ] **結果確認**: CS 長分布 (p50, mean)
- [ ] **push**: `EXPERIMENT_TYPE=hold bash experiment/push_results.sh`
- [ ] **2-c**: `hold_sweep (GET 100%)` — `UPDATE_RATIO=0.0 MEMCACHED_BIN=$MEMCACHED_HOLD_BIN bash experiment/run_hold_sweep.sh`
- [ ] **結果確認**: item_lock 単独競合の CS 長 (mixed より短い想定)
- [ ] **push**: `EXPERIMENT_TYPE=hold bash experiment/push_results.sh`
- [ ] **2-d**: `hold_sweep (SET 100%)` — `UPDATE_RATIO=1.0 MEMCACHED_BIN=$MEMCACHED_HOLD_BIN bash experiment/run_hold_sweep.sh`
- [ ] **結果確認**: item_lock + slabs_lock の CS 長 (mixed より長い想定)
- [ ] **push**: `EXPERIMENT_TYPE=hold bash experiment/push_results.sh`
- [ ] **2-e**: `futex_sweep` — `unset MEMCACHED_BIN && bash experiment/run_futex_sweep.sh`
- [ ] **結果確認**: futex/req が N と共に減少 (N=1 で激減)
- [ ] **push**: `EXPERIMENT_TYPE=futex bash experiment/push_results.sh`

**サーバ別チェック** (全 5 アーキで実施):
- [ ] Ivy Bridge (c8220) — Phase 2 完了
- [ ] Broadwell (xl170) — Phase 2 完了
- [ ] Skylake (c220g5) — Phase 2 完了
- [ ] Sunny Cove (sm110p) — Phase 2 完了
- [ ] Emerald Rapids (c6620) — Phase 2 完了

**サーバ 1 台あたり総所要時間**: 7h × 5 実験 = **~35h** (2 泊 3 日、並列で 1 日半)

---

## Phase 3: 感度実験 (UPDATE_RATIO × RECORDS)

Phase 1/2 で確定した「アーキごとに peak N が異なる」を、ワークロード変化でも同様に成り立つか検証する。

### Phase 3-a: UPDATE_RATIO 感度 (utdelay、3 アーキ、~42h/アーキ 並列)

**対象アーキ**: Broadwell + Skylake + Emerald (peak N 対極 + budget outlier)

**追加パターン** (default 0.5 は既存):
- [ ] Broadwell / UPDATE_RATIO=0.0 (GET 100%) — `UPDATE_RATIO=0.0 bash experiment/run_utdelay_sweep_p999.sh` (~21h)
- [ ] Broadwell / UPDATE_RATIO=1.0 (SET 100%) — `UPDATE_RATIO=1.0 bash experiment/run_utdelay_sweep_p999.sh` (~21h)
- [ ] Skylake  / UPDATE_RATIO=0.0
- [ ] Skylake  / UPDATE_RATIO=1.0
- [ ] Emerald  / UPDATE_RATIO=0.0
- [ ] Emerald  / UPDATE_RATIO=1.0

**push**: `EXPERIMENT_TYPE=utdelay bash experiment/push_results.sh` (同じ日 or 別ラベル追加が要検討)

**分析**: 3 パターン (0.0/0.5/1.0) を並べて、peak N がどう動くかを見る。**最も peak N がシフトしそうな設定**を Phase 3-b の対象にする。

### Phase 3-b: RECORDS 感度 (utdelay、Phase 3-a で選定した UPDATE_RATIO のみ)

**RECORDS 値の候補** (現状 default = 1 = 単一 hot key 最大競合):
- 1 (default、既存データ)
- 10,000 (~10k、中規模: セッションストア、CDN edge cache)
- 1,000,000 (~1M、大規模: 商品カタログ、ユーザプロファイル)

**対象**: Phase 3-a の分析で選んだ UPDATE_RATIO × 3 アーキ (Broadwell + Skylake + Emerald)

**追加パターン**:
- [ ] Broadwell / 選定 UPDATE_RATIO / RECORDS=10000 — `RECORDS=10000 UPDATE_RATIO=<x> bash experiment/run_utdelay_sweep_p999.sh` (~21h)
- [ ] Broadwell / 選定 UPDATE_RATIO / RECORDS=1000000
- [ ] Skylake / (同上、2 パターン)
- [ ] Emerald / (同上、2 パターン)

**分析**: contention 度が下がると peak N がどう動くか、絶対改善率がどう縮むかを見る。**「PAUSE tuning はどのシチュエーションで効くか」**を定量化する。

---

## Phase 4: 全結果の収集と可視化

- [ ] cloudlab 5 サーバから ann サーバへ結果を pull
  ```bash
  cd ~/Application/memcached && git fetch myfork && bash experiment/collect_results.sh
  ```
- [ ] 各アーキの結果構造を確認
  ```bash
  for a in ivybridge broadwell skylake icelake emeraldrapids skylake_ann; do echo "== $a =="; ls experiment/results/$a/; done
  ```
- [ ] 5 アーキで揃うグラフ再生成
  ```bash
  OUTPUT_DIR=experiment/results/plots/v5 python3 experiment/plot_qps_production.py       # QPS 4-5 archs
  OUTPUT_DIR=experiment/results/plots/v5 python3 experiment/plot_handoff_comparison.py   # handoff (cycles)
  OUTPUT_DIR=experiment/results/plots/v5 python3 experiment/plot_cache_miss_comparison.py
  OUTPUT_DIR=experiment/results/plots/v5 python3 experiment/plot_futex_comparison.py
  # unlock / hold 全アーキ比較スクリプトは Phase 2 完了後に新規作成
  ```
- [ ] research_summary.html の数値・グラフを最新に更新

---

## 実行順序の推奨

1. **cloudlab 5 サーバ順次 Phase 1** (1 サーバ 36h、各 2 泊 3 日相当)
   - 順: c8220 (Ivy) → xl170 (Broadwell) → c220g5 (Skylake) → sm110p (Sunny Cove) → c6620 (Emerald)
   - サーバ返却前に必ず 3 種 push
2. **cloudlab 5 サーバ Phase 2** (setup_cloudlab.sh 更新後、~35h/サーバ)
   - 全アーキで unlock + hold × 3 + futex を回す
   - Phase 1 と同じサーバで連続実施できる場合はそのまま
3. **Phase 3 sensitivity** (Broadwell + Skylake + Emerald)
   - Phase 3-a: UPDATE_RATIO 0.0/1.0 各アーキ 2×21h = 42h/サーバ (並列で 42h wall)
   - Phase 3-b: 選定 UPDATE_RATIO で RECORDS 変更、2 パターン × 3 アーキ (並列で 42h wall)
4. **Phase 4 集計・可視化・論文執筆**

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
