# Plot v1 — 初期分析グラフ (p999修正前 / 旧スクリプト)

生成時期: 2026年6月〜7月初旬

## 概要

p999 対応の mutilate_p999 ビルド前、または RUNS<20 の初期実験データを使って
生成した分析グラフ群。比較・参照用として保管。

## ファイル一覧

| ファイル                          | 内容 |
|----------------------------------|------|
| utdelay_arch_qps.png             | アーキ別 QPS vs N (旧フォーマット) |
| utdelay_arch_r_avg.png           | アーキ別 avg レイテンシ vs N |
| utdelay_arch_r_p99.png           | アーキ別 p99 レイテンシ vs N |
| utdelay_arch_normalized.png      | 正規化スループット比較 |
| cdf_latency_p999_skylake_ann.png | skylake_ann CDF (p999対応前) |
| pause_spinlock_skylake_ann_qps.png | skylake_ann QPS sweep (旧) |

## 備考

- p999 カラムは未対応または空のデータを使用
- RUNS数が実験によって異なる (一部 RUNS<20)
- v2 が正式版
