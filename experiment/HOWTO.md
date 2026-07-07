# 実験手順書 — memcached PAUSE sweep & wait-time distribution

## ファイル構成

```
experiment/
├── cloudlab_profile_v2.py       ← CloudLab プロファイル（CloudLab にアップロード）
├── setup_cloudlab.sh            ← 新規ノード自動セットアップ（results ブランチから取得）
├── setup_perf_env.sh            ← CPU 環境固定（SMT off, turbo off, governor=performance）
├── run_trial.sh                 ← 両実験の短時間動作確認
├── run_experiments.sh           ← 両実験の本番実行（utdelay → wait → push）
├── run_utdelay_sweep_p999.sh    ← utdelay sweep 単体実行
├── run_wait_distribution.sh     ← spinlock wait-time 単体実行
├── push_results.sh              ← 結果を myfork へ push
├── fetch_wait_bins.sh           ← ann サーバで .bin ファイルを CloudLab から取得
├── collect_results.sh           ← ann サーバで myfork から結果を収集（git）
├── extract_wait_stats.py        ← .bin → wait_summary.csv
├── plot_arch_comparison.py      ← アーキテクチャ比較グラフ（utdelay）
├── plot_wait_arch_comparison.py ← アーキテクチャ比較グラフ（wait）
└── config/htop/htoprc           ← htop 設定ファイル
```

---

## ハードウェアマッピング

| アーキテクチャ | CloudLab HW | CPU | PAUSE サイクル |
|---|---|---|---|
| broadwell | xl170 (Utah) | Xeon E5-2640 v4 | ~12 cyc |
| ivybridge | c8220 (Clemson) | Xeon E5-2650 v2 | ~15 cyc |
| skylake | c220g5 (Wisconsin) | Xeon Silver 4114 | ~142 cyc |
| icelake | sm110p (Wisconsin) | Xeon Gold 6338 / Silver 4314 | ~39 cyc |
| emeraldrapids | c6620 (Utah) | Xeon Gold 6554S | ~37 cyc |

skylake_ann は annサーバ本体（CloudLab ではなし）。

---

## Step 1: CloudLab プロファイルの登録

**プロファイルファイル**: `experiment/cloudlab_profile_v2.py`
（CloudLab 上のプロファイル名: `small-lan-test-memcached-v2`）

1. CloudLab (https://www.cloudlab.us) にログイン
2. Experiments → Create Experiment Profile
3. `experiment/cloudlab_profile_v2.py` の内容をアップロード or ペースト
4. Save

> プロファイルの `SETUP_URL` は `results` ブランチの `setup_cloudlab.sh` を指している:
> ```
> https://raw.githubusercontent.com/hikaru2003/memcached/results/experiment/setup_cloudlab.sh
> ```
> → 新規ノード起動時に自動的に最新スクリプトが取得・実行される。

---

## Step 2: 新規ノードの起動

1. CloudLab → Experiments → Start Experiment → プロファイルを選択
2. ハードウェアタイプを UI で手動選択（例: xl170 = broadwell）
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

`run_trial.sh` / `run_experiments.sh` が自動で `setup_perf_env.sh` を呼び出す。
手動で再適用する場合:

```bash
sudo bash /users/Morisaki/memcached/experiment/setup_perf_env.sh
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
cd /users/Morisaki/memcached
bash experiment/run_trial.sh
```

デフォルトパラメータ: `WARMUP=30s, DURATION=30s, RUNS=1, N="0 4 30"`

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

```bash
cd /users/Morisaki/memcached
bash experiment/run_experiments.sh
```

**実行フロー**:
1. CPU 環境設定（`setup_perf_env.sh` 自動実行）
2. utdelay sweep（~12.6 時間）
3. **utdelay 結果を myfork へ push**
4. wait distribution（~5.3 時間）
5. wait 結果を myfork へ push

**実験パラメータ（本番デフォルト）**:
| パラメータ | utdelay | wait |
|---|---|---|
| WARMUP_SEC | 300s | 300s |
| DURATION | 60s | 60s |
| RUNS | 20 | 5 |
| SPIN_ROUNDS | 30 | 30 |
| PAUSE_PER_ROUND_VALUES | `0 1 2 3 4 5 6 7 8 9 10 15 20 25 30 35 40 45 50 55 60 65 70 75 80 85 90 95 100 150 200` ||

推定合計時間: **約 18 時間**

**出力**:
```
experiment/results/utdelay_p999_YYYYMMDD_HHMMSS/
  run_info.md    - 実験パラメータ
  raw.csv        - 全ランの生データ（QPS, r_avg, r_p50, r_p99, r_p999）
  summary.md     - N別統計テーブル
  raw/           - mutilate 生ログ（run_<label>_<n>.log）

experiment/results/wait_dist_YYYYMMDD_HHMMSS/
  run_info.md                     - 実験パラメータ
  N<n>/wait_samples_thread<t>.bin - rdtsc サイクル単位のサンプル（uint64_t）
  wait_summary.csv                - パーセンタイル統計
```

> `.bin` ファイルは git push されない（~1GB/サーバ）。ann サーバへは Step 7b で scp 取得する。

---

## Step 6: ann サーバで結果を収集（git）

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

## Step 7b: .bin ファイルの取得（scp）

wait distribution の生サンプル（`.bin`）は git 管理外。ann サーバから直接取得する。

```bash
# ann サーバ（本機）で実行
cd ~/Application/memcached
bash experiment/fetch_wait_bins.sh <node_host> [arch_name]

# 例
bash experiment/fetch_wait_bins.sh hp142.utah.cloudlab.us broadwell
bash experiment/fetch_wait_bins.sh clnode018.clemson.cloudlab.us ivybridge
```

アーキ名を省略すると CPU モデルから自動検出する。
`.bin` ファイルは `experiment/results/<arch>/wait_dist_*/N*/` に配置される。

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
| `/users/Morisaki/memcached/memcached` | `experiment/mysql-like-utdelay` | utdelay sweep 計測用 |
| `/users/Morisaki/memcached/memcached_master` | `master` | baseline（スピンなし） |
| `/users/Morisaki/memcached/memcached_wait_debug` | `debug/wait-time` | wait-time 計測用 |
| `/users/Morisaki/mutilate/mutilate` | leverich/mutilate | 標準ロードジェネレータ |
| `/users/Morisaki/mutilate/mutilate_p999` | 同上（ConnectionStats.h パッチ済み） | p50+p999 計測用 |

---

## トラブルシューティング

### セットアップログを確認

```bash
tail -100 /tmp/setup_memcached.log
```

### バイナリが存在しない

```bash
SKIP_PKG=1 sudo bash /users/Morisaki/memcached/experiment/setup_cloudlab.sh
```

### ポート競合（`failed to listen on TCP port 11222`）

```bash
fuser -k 11222/tcp
```

### `numpy` が見つからない

```bash
sudo apt install -y python3-numpy python3-matplotlib
```

### push が失敗する（Permission denied）

`ssh -A`（エージェント転送）なしでログインしている。ローカルで:
```bash
ssh-add ~/.ssh/id_ed25519
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
| N=20–100 | step-5 | Broadwell で N=30(peak)→N=50(急落)→N=80(回復、spread=19K) の振動を確認 |
| N=150, 200 | — | 漸近挙動の確認 |
