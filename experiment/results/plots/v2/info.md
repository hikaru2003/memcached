# Plot v2 — broadwell / icelake / skylake_ann (RUNS=20, p999 取得済み)

生成日: 2026-07-09
生成スクリプト: `experiment/plot_results_p999.py`

## 使用データ

### utdelay sweep

| arch        | 実験ディレクトリ                                                      | RUNS | 環境 |
|-------------|----------------------------------------------------------------------|------|------|
| broadwell   | experiment/results/broadwell/utdelay_p999_20260707_022638/raw.csv   | 20   | CloudLab xl170 (Xeon E5-2640 v4) |
| icelake     | experiment/results/icelake/utdelay_p999_20260707_090726/raw.csv     | 20   | CloudLab sm110p (Xeon Silver 4314) |
| skylake_ann | experiment/results/utdelay_p999_20260708_233528/raw.csv             | 20   | annサーバ (Silver 4110, PAUSE~142cyc) |

### wait distribution

| arch        | 実験ディレクトリ                                                     |
|-------------|---------------------------------------------------------------------|
| broadwell   | experiment/results/broadwell/wait_dist_20260707_154814/            |
| icelake     | experiment/results/icelake/wait_dist_20260707_222901/              |
| skylake_ann | experiment/results/wait_dist_20260709_225409/                      |

## 実験条件

- spinlock: [trylock → PAUSE×N] × 30 → mutex_lock
- memcached: 4スレッド (cpu 0-3)
- mutilate: -T4 -c1 -d32 -r1 -u0.5
- warmup: 300s / duration: 60s / RUNS: 20
- N値: 0 1 2 3 4 5 6 7 8 9 10 15 20 25 30 35 40 45 50 55 60 65 70 75 80 85 90 95 100 150 200

## 出力ファイル

| ファイル                         | 内容 |
|---------------------------------|------|
| qps_comparison.pdf              | QPS vs N (3アーキ比較, エラーバー=CV%) |
| qps_normalized.pdf              | 正規化QPS vs N (master比, 棒グラフ+p50折れ線, エラーバー=CV%) |
| latency_boxplot.pdf             | レイテンシ箱ひげ図 (代表N値, 3アーキ比較) |
| wait_distribution.pdf           | ロック獲得待ち時間 p50/p99/p999 vs N |
| latency_boxplot_broadwell.pdf   | broadwell 全N値 箱ひげ図 |
| latency_boxplot_icelake.pdf     | icelake 全N値 箱ひげ図 |
| latency_boxplot_skylake_ann.pdf | skylake_ann 全N値 箱ひげ図 |

## エラーバーの定義

エラーバーには **CV%（変動係数, Coefficient of Variation）** を使用する。

```
CV% = std / mean × 100
エラーバー高さ = CV% / 100 × mean = std  (絶対値としてはstdと等価)
```

**stdではなくCV%を採用する理由:**

- N値によってQPS自体が大きく変わる（N=0: ~1000K, N=45: ~1414K）
- stdの絶対値はQPSの大きさに引きずられるため、N間・アーキ間の「安定性」比較に不向き
- CV%はmeanで正規化した相対的ばらつきであり、実験の再現性を公平に比較できる
- 例: N=0 (std=5K, mean=1000K → CV=0.5%) vs N=45 (std=50K, mean=1414K → CV=3.5%)
  → stdだけ見ると50K≫5Kだが、CV%で見ると3.5% vs 0.5%と解釈が明確になる

## 箱ひげ図の定義

- 上ひげ: p999
- 箱上端: p99
- 箱下端: p50
- 下ひげ: min (raw/*.log から取得)
- 各値: 20ラン中央値

## グラフ再生成

```bash
cd ~/Application/memcached
python3 experiment/plot_results_p999.py
# 次バージョン:
OUTPUT_DIR=experiment/results/plots/v3 python3 experiment/plot_results_p999.py
```
