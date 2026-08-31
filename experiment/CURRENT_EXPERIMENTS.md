# 進行中の実験手順（2026-08-27）

## サーバ割り当て

| サーバ | ノード種別 | 主タスク | 状態 |
|---|---|---|---|
| c6620 | Emerald Rapids (Gold 5512U) | cache_miss sweep → PAUSE実測（-O2） | **結果待ち**（サーバ返却済み） |
| xl170 | Broadwell (E5-2640 v4) | Approach A | 実施予定 |
| sm110 | Ice Lake (Silver 4314) | 完了（PAUSE実測のみ） | 返却済み |

### PAUSE実測済み値（-O2コンパイル）

| アーキテクチャ | 実測値 |
|---|---|
| Broadwell (xl170) | 10.05 cy |
| Ice Lake (sm110) | 38.74 cy |
| Skylake ann | 124.20 cy |
| Emerald Rapids (c6620) | **37.16 cy** |

---

## 全サーバ共通: PAUSE サイクル実測（~30秒）

```bash
gcc -O2 ~/simple_mysql/pause_cycle_count.c -o /tmp/pause_cycle_count
taskset -c 0 /tmp/pause_cycle_count
```

出力された数値（例: `152.3`）をメモする。

---

## c6620（Emerald Rapids）— cache miss sweep

### setup（未実施なら）
```bash
sudo bash experiment/setup_perf_env.sh
```

### 本実験（~2〜3時間）
```bash
cd ~/Application/memcached
bash experiment/run_cache_miss_sweep.sh
```

### 完了後: 結果を push
```bash
EXPERIMENT_TYPE=cache_miss bash experiment/push_results.sh
```

---

## xl170（Broadwell）— Approach A: スレッド数変化実験

**目的**: N を固定しスレッド数を変えることで、RFO 増加 → handoff latency 増加の因果を確認する。

全体所要時間: ~90分

```bash
cd ~/Application/memcached
bash experiment/run_approach_a.sh
```

スクリプトが MC_THREADS=2/4/8 の handoff + cache_miss を順番に実行し、
終了後に `experiment/results/approach_a_*/approach_a_summary.md` を生成する。

### 完了後: 結果を push
```bash
EXPERIMENT_TYPE=handoff bash experiment/push_results.sh
EXPERIMENT_TYPE=cache_miss bash experiment/push_results.sh
```

---

## sm110（Ice Lake）— PAUSE実測のみ

```bash
gcc -O2 ~/simple_mysql/pause_cycle_count.c -o /tmp/pause_cycle_count
taskset -c 0 /tmp/pause_cycle_count
```

余裕があれば xl170 と同様に Approach A も実施する。

---

## 期待する結果（Approach A）

固定 N（例: N=50）でスレッド数を増やすと：

```
MC_THREADS:  2     →    4     →    8
demand_rfo:  低    →    中    →    高
handoff p99: 短    →    中    →    長
```

両者が同方向に増加すれば「RFO 増加 → handoff latency 増加」の相関が取れる。

---

## 参照

- 実験スクリプト: `experiment/run_cache_miss_sweep.sh`, `experiment/run_handoff_sweep.sh`
- 結果の push: `experiment/push_results.sh`
- Notion (cache miss): https://app.notion.com/p/3973263a1028803f9b36fe82438fbce5
- Notion (futex sweep): https://app.notion.com/p/3ad3263a102881db9160c0b25db662d6
