# 実験再開ステータス (作成: 2026-09-29 光)

前回セッション: 2026-09-17。以降 12 日間空き、cloudlab サーバは全台返却済み。
再開時に「どこまで済み、どこから始めるか」を掴むための単一ソース。

---

## 1. 完了済み（myfork にプッシュ済み、再取得不要）

### Phase 1: throughput + N sweep
- utdelay_p999 sweep (production): 4 arch 完了
  - broadwell / skylake / icelake(=Sunny Cove) / emeraldrapids
  - branch: `myfork/experiment/results/{arch}-utdelay-YYYYMMDD`
  - 環境: SMT off / governor performance / turbo off / base clock pin
  - 統計: warmup 120s + 60s × 30 runs / N、40 N grid
  - **論文の主結果 (アブスト値の出所)**

- cache_miss sweep (RFO): 4 arch 完了
  - branch: `myfork/experiment/results/{arch}-cache_miss-YYYYMMDD`
  - Emerald は `offcore_requests.demand_rfo`、他は `l2_rqsts.rfo_miss`

- handoff latency sweep: 4 arch 完了
  - branch: `myfork/experiment/results/{arch}-handoff-YYYYMMDD`

### Phase 2 (部分完了)
- unlock latency sweep: 4 arch 完了 (0916 or 0917)
  - branch: `myfork/experiment/results/{arch}-unlock-2026091{5,6,7}`

- hold_mixed sweep (UPDATE_RATIO=0.5, split バイナリ使用): 4 arch プッシュ済
  - branch: `myfork/experiment/results/{arch}-hold-20260917`
  - ⚠️ **既知バグ**: `run_hold_sweep.sh` が `hold_item_samples_thread*.bin` を N<n>/ に収集していなかったため、
    プッシュされた `hold_summary.csv` は slabs_lock 側のみ (item_lock サンプルは cloudlab 上で消失、cloudlab 返却済み)。
  - 修正は本ローカルの working tree に済み (未コミット、下記 2 節参照)。

---

## 2. 未コミットのローカル変更 (再開前に必ず処理)

```
 M experiment/plot_qps_production.py
 M experiment/results/plots/v4/qps_comparison_production_n30.pdf
 M experiment/results/plots/v4/qps_normalized_production_n30.pdf
 M experiment/results/plots/v4/qps_pause_budget_production_n30.pdf
 M experiment/run_hold_sweep.sh
```

内訳:

1. **`plot_qps_production.py`**: Gaussian フィルタを除去し PCHIP のみに戻した。
   全実測点を通過、点間のみ滑らか。3 PDF は再生成済み。

2. **`run_hold_sweep.sh`**: `hold_item_samples_thread*.bin` の収集ロジックを追加。
   split バイナリ利用時に item_lock 側の CS 時間サンプルも N<n>/ に残るようになる。

いずれも **cloudlab を再度借りる前** に results ブランチにコミット & push しておく。

```bash
git add experiment/plot_qps_production.py experiment/run_hold_sweep.sh \
        experiment/results/plots/v4/qps_*.pdf
git commit -m "experiment: fix hold sweep item bin collection + PCHIP-only QPS smoothing"
git push myfork results
```

---

## 3. 未実施の実験 (優先順)

cloudlab を再度借りたら、4 arch 並列で以下を順次流す。

### 優先度 高: hold sweep やり直し (split 完全版)
既存 hold_mixed は slabs 側のみ有効。item_lock 側を取り直すためには split バイナリで再実行が必要。
上記 2 節の run_hold_sweep.sh 修正をコミット & 各 cloudlab で pull してから開始する。

- [ ] hold_mixed (UPDATE_RATIO=0.5) 再測定 — 4 arch × ~7h
  - 修正済みスクリプトなら slabs + item 両方の .bin が残る
- [ ] hold_get100 (UPDATE_RATIO=0.0) — 4 arch × ~7h
- [ ] hold_set100 (UPDATE_RATIO=1.0) — 4 arch × ~7h

### 優先度 中: futex sweep
- [ ] futex sweep — 4 arch × ~7h
  - branch: `myfork/experiment/results/{arch}-futex-YYYYMMDD` (broadwell 0728 / icelake 0806 は古い、skylake / emerald は未実施)

### 優先度 低 (Phase 3): sensitivity study
- [ ] UPDATE_RATIO × RECORDS の 2 次元スイープ
  - 論文本体の主張には不要、appendix or 別稿

---

## 4. 再開手順 (cloudlab を借り直したときのチェックリスト)

1. `experiment/CLOUDLAB_RUN.md` の setup 節に沿って 4 サーバ起動
   - SMT off / governor / turbo / freq pin
   - `bash experiment/setup_cloudlab.sh` で debug バイナリ全部ビルド
     - memcached_v2 (production)
     - memcached_handoff_debug (debug/handoff-latency)
     - memcached_unlock_debug (debug/unlock-latency)
     - memcached_hold_debug (debug/hold-split)  ← Phase 2 hold で使う
2. **`git pull` で本ローカルからコミット済みの修正版 run_hold_sweep.sh を反映**
3. `experiment/CURRENT_EXPERIMENTS.md` の該当セクションに沿って sweep 実行
4. 完了後 `EXPERIMENT_TYPE=<type> bash experiment/push_results.sh`

---

## 5. 論文執筆の状況

### アブスト
- v6 まで書き、Notion に保存: https://app.notion.com/p/3de3263a102880318ce4f9ef3d0aa3ac
- **主主題**: 最適 N はアーキ間で 4 倍異なる (Broadwell N=40 / Skylake N=10)
- **副主題は 2 章 (Background) に格下げ確定** (2026-09-29 先生確認)
  - Background の順序:
    1. スピンロックにおいては待機時にスピンをして待つのが推奨されている
    2. しかし memcached はデフォルトで即スリープする実装
    3. スピンを導入するだけでこれだけ QPS が改善する (1.37×〜1.56×)
    4. さらに PAUSE を挟むとこれだけ改善する
    5. しかし最適な PAUSE 挿入回数はアーキで異なる — なぜなら PAUSE サイクル数がアーキで違うから
- **次アクション**: 上記順序に沿って Background を書き下ろす → その後アブスト再ブラッシュアップ

### 章立て提案
- 未着手 (前回セッションの B タスク)
- Background の順序が確定したので、章立ても以下を軸に組める:
  - 1 Introduction (アブストと同じ流れ)
  - 2 Background (上記 5 段の順序)
  - 3 Proposal / Implementation (memcached への MySQL 風スピン導入)
  - 4 Methodology (実験環境)
  - 5 Evaluation (Phase 1 + Phase 2)
  - 6 Discussion
  - 7 Related Work
  - 8 Conclusion

### 実データ (アブスト用)
| Arch | PAUSE cy | 最適 N | 最適 QPS | Master QPS | Master 比 |
|---|---:|---:|---:|---:|---:|
| Broadwell (xl170)       | ~10  | 40 | 1404k | 915k  | 1.53× |
| Sunny Cove (sm110p)     | ~39  | 17 | 1501k | 1095k | 1.37× |
| Emerald Rapids (c6620)  | ~37  | 28 | 1324k | 952k  | 1.39× |
| Skylake (c220g5)        | ~140 | 10 | 1124k | 722k  | 1.56× |

- 最適 N のアーキ間比: 40 / 10 = 4×
- Master 比改善: 1.37× 〜 1.56× (Skylake 最大 — background で強調)

---

## 6. 参考リンク

- 論文投稿先: ComSys 2026 / IPSJ SIG-OS (〆切 2026-10-16)
- Notion アブスト: https://app.notion.com/p/3de3263a102880318ce4f9ef3d0aa3ac
- 主要スクリプトのランブック: `experiment/CLOUDLAB_RUN.md`
- 実験セット一覧: `experiment/CURRENT_EXPERIMENTS.md`
- Smoke test 手順: `experiment/SMOKE_TEST.md`
