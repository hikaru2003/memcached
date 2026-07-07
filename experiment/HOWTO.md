# 実験手順書 — memcached PAUSE sweep & wait-time distribution

## ファイル構成

```
experiment/
├── cloudlab_profile.py          ← CloudLab プロファイル（ここを CloudLab にアップロード）
├── setup_cloudlab.sh            ← 新規ノード自動セットアップ（results ブランチから取得）
├── setup_perf_env.sh            ← CPU 環境固定（SMT off, turbo off, governor=performance）
├── run_trial.sh                 ← 両実験の短時間動作確認
├── run_utdelay_sweep_p999.sh    ← utdelay sweep 本番実験
├── run_wait_distribution.sh     ← spinlock wait-time 本番実験
├── push_results.sh              ← 結果を myfork へ push
├── collect_results.sh           ← ann サーバで myfork から結果を収集
├── extract_wait_stats.py        ← .bin → wait_summary.csv
├── plot_arch_comparison.py      ← アーキテクチャ比較グラフ（utdelay）
└── plot_wait_arch_comparison.py ← アーキテクチャ比較グラフ（wait）
```

---

## ハードウェアマッピング

| アーキテクチャ | CloudLab HW | CPU | PAUSE サイクル |
|---|---|---|---|
| broadwell | xl170 | Xeon E5-2640 v4 | ~12 cyc |
| ivybridge | c8220 | Xeon E5-2650 v2 | ~15 cyc |
| skylake | c220g5 | Xeon Silver 4114 | ~142 cyc |
| icelake | sm110 | Xeon Gold 6338 | ~39 cyc |
| emeraldrapids | c6620 | Xeon Gold 6554S | ~37 cyc |

skylake_ann は annサーバ本体（CloudLab ではなし）。

---

## Step 1: CloudLab プロファイルの登録

**プロファイルファイル**: `experiment/cloudlab_profile.py`

1. CloudLab (https://www.cloudlab.us) にログイン
2. Experiments → Create Experiment Profile
3. `experiment/cloudlab_profile.py` の内容をアップロード or ペースト
4. Profile name: 任意（例: `memcached-pause-sweep`）
5. Save

> プロファイルの `SETUP_URL` は `results` ブランチの `setup_cloudlab.sh` を指している:
> ```
> https://raw.githubusercontent.com/hikaru2003/memcached/results/experiment/setup_cloudlab.sh
> ```
> → 新規ノード起動時に自動的に最新スクリプトが取得・実行される。

---

## Step 2: 新規ノードの起動

1. CloudLab → Experiments → Start Experiment → プロファイルを選択
2. パラメータ設定:
   - **Target Architecture**: 対象アーキテクチャ（例: broadwell）
   - Hardware type override: 空欄でよい（HW_MAP から自動選択）
3. ノード起動（Provisioning が完了するまで待つ）
4. ログ確認:
   ```bash
   ssh -A Morisaki@<node>.cloudlab.us
   tail -f /tmp/setup_memcached.log
   ```
   最後に `Setup complete!` が出ればセットアップ完了（所要約 10〜15 分）。

> **`ssh -A`（エージェント転送）が必須**。`push_results.sh` が `git push` を行う際に
> ローカルの SSH 鍵を使用する。

---

## Step 3: CPU 環境の確認と固定

セットアップスクリプトが自動的に `setup_perf_env.sh` を呼び出す。
手動で再確認・再適用する場合:

```bash
sudo bash ~/Application/memcached/experiment/setup_perf_env.sh
```

**適用内容**:
- SMT (Hyper-Threading) を無効化
- `intel_pstate` を passive モードに切り替え
- governor → `performance`
- Turbo Boost を無効化
- `scaling_min_freq = scaling_max_freq` でベースクロックにピン留め

> 設定はリブートで元に戻る（永続化しない）。

---

## Step 4: 動作確認（trial run）

本番実験の前に短時間パラメータで両実験が動くことを確認する。

```bash
cd ~/Application/memcached
bash experiment/run_trial.sh
```

デフォルトパラメータ: `WARMUP=30s, DURATION=30s, RUNS=1, N="0 4 30"`

カスタマイズ例:
```bash
WARMUP_SEC=60 DURATION=60 RUNS=2 PAUSE_VALUES="0 4 30" \
  bash experiment/run_trial.sh
```

**確認ポイント**:
- `[OK] All binaries found.` が出ること
- utdelay sweep と wait distribution が両方完走すること
- `push_results.sh` が成功すること（`ssh -A` でログインしていること）

push をスキップして確認のみ行う場合:
```bash
SKIP_PUSH=1 bash experiment/run_trial.sh
```

---

## Step 5: 本番実験

### 5a. utdelay sweep（p50 + p999 レイテンシー計測）

**自動生成されたラッパーで実行**（推奨）:
```bash
bash ~/run_utdelay_experiment.sh
```

このラッパーにはアーキテクチャ別の `MC_CPUS` / `WL_CPUS` が設定済み。

直接実行する場合:
```bash
cd ~/Application/memcached
bash experiment/run_utdelay_sweep_p999.sh
```

**実験パラメータ（本番デフォルト）**:
| パラメータ | 値 |
|---|---|
| WARMUP_SEC | 300s |
| DURATION | 60s |
| RUNS | 20 |
| SPIN_ROUNDS | 30 |
| PAUSE_PER_ROUND_VALUES | `0 1 2 3 4 5 6 7 8 9 10 15 20 25 30 35 40 45 50 55 60 65 70 75 80 85 90 95 100 150 200` |

推定所要時間: 32条件 × (300 + 20×60)s ≈ **12.6 時間**

**出力**:
```
experiment/results/utdelay_p999_YYYYMMDD_HHMMSS/
  run_info.md    - 実験パラメータ
  raw.csv        - 全ランの生データ（QPS, r_avg, r_p50, r_p99, r_p999, ...）
  summary.md     - N別統計テーブル
  raw/           - mutilate ログ
```

---

### 5b. wait-time distribution（spinlock 待ち時間計測）

```bash
cd ~/Application/memcached
bash experiment/run_wait_distribution.sh
```

**実験パラメータ（本番デフォルト）**:
| パラメータ | 値 |
|---|---|
| WARMUP_SEC | 300s |
| DURATION | 60s |
| RUNS | 5 |
| SPIN_ROUNDS | 30 |
| PAUSE_PER_ROUND_VALUES | `0 1 2 3 4 5 6 7 8 9 10 15 20 25 30 35 40 45 50 55 60 65 70 75 80 85 90 95 100 150 200` |

推定所要時間: 32条件 × (300 + 5×60)s ≈ **5.3 時間**

**出力**:
```
experiment/results/wait_dist_YYYYMMDD_HHMMSS/
  run_info.md                     - 実験パラメータ
  N<n>/wait_samples_thread<t>.bin - rdtsc サイクル単位のサンプル（uint64_t）
  wait_summary.csv                - extract_wait_stats.py が生成する統計CSV
```

> `.bin` ファイルはサイズが大きいため push されない。`wait_summary.csv` のみ push される。

---

## Step 6: 結果の push（CloudLab サーバ上で実行）

```bash
cd ~/Application/memcached

# utdelay sweep 結果
bash experiment/push_results.sh

# wait distribution 結果
EXPERIMENT_TYPE=wait bash experiment/push_results.sh
```

push 先ブランチ:
```
experiment/results/<arch>-utdelay-YYYYMMDD
experiment/results/<arch>-wait-YYYYMMDD
```

> `myfork` リモート = `git@github.com:hikaru2003/memcached.git`
> SSH エージェント転送（`ssh -A`）が必要。

---

## Step 7: ann サーバで結果を収集

```bash
# ann サーバ（本機）で実行
cd ~/Application/memcached

git fetch myfork
bash experiment/collect_results.sh
```

収集後の構成:
```
experiment/results/
├── broadwell/
│   ├── utdelay_p999_YYYYMMDD_HHMMSS/
│   └── wait_dist_YYYYMMDD_HHMMSS/
├── ivybridge/
├── skylake/
├── skylake_ann/    ← ann サーバ本体のシンボリックリンク
└── emeraldrapids/
```

---

## Step 8: グラフ生成（ann サーバで実行）

```bash
cd ~/Application/memcached

# アーキテクチャ比較（utdelay sweep）
python3 experiment/plot_arch_comparison.py

# アーキテクチャ比較（wait-time distribution）
python3 experiment/plot_wait_arch_comparison.py
```

---

## バイナリ一覧

| バイナリ | ブランチ | 用途 |
|---|---|---|
| `~/Application/memcached/memcached` | `experiment/mysql-like-utdelay` | utdelay sweep 計測用 |
| `~/Application/memcached/memcached_master` | `master` | baseline（スピンなし） |
| `~/Application/memcached/memcached_wait_debug` | `debug/wait-time` | wait-time 計測用 |
| `~/Application/mutilate/mutilate` | leverich/mutilate | 標準ロードジェネレータ |
| `~/Application/mutilate/mutilate_p999` | 同上（ConnectionStats.h パッチ済み） | p50+p999 計測用 |

---

## トラブルシューティング

### セットアップログを確認

```bash
tail -100 /tmp/setup_memcached.log
```

### バイナリが存在しない

```bash
# SKIP_PKG=1 でパッケージインストールをスキップして再ビルド
SKIP_PKG=1 bash ~/Application/memcached/experiment/setup_cloudlab.sh
```

### ポート競合（`failed to listen on TCP port 11222`）

前回の memcached プロセスが残留している。`start_memcached()` 内の `fuser -k` で自動対処済み。
手動でクリアする場合:
```bash
fuser -k 11222/tcp
```

### `numpy` が見つからない

```bash
sudo apt-get install -y python3-numpy python3-matplotlib
```

### push が失敗する（Permission denied）

`ssh -A`（エージェント転送）なしでログインしている。ローカルで:
```bash
ssh-add ~/.ssh/id_ed25519   # 鍵を agent に追加
ssh -A Morisaki@<node>.cloudlab.us
```

### アーキテクチャが自動検出されない

```bash
ARCH_NAME=broadwell bash experiment/push_results.sh
```

---

## N値の根拠（PAUSE_PER_ROUND_VALUES）

| 範囲 | 刻み | 理由 |
|---|---|---|
| N=0–10 | step-1 | 小N域で QPS が局所的に振動する（Broadwell: N=7 が局所 peak） |
| N=15 | — | 10→20 の補間 |
| N=20–100 | step-5 | Broadwell で N=30(peak)→N=50(急落)→N=80(回復、spread=19K) の振動を確認。細分化が必要 |
| N=150, 200 | — | 漸近挙動の確認 |
