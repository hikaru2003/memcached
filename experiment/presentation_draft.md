# 中間発表 — 発表内容ドラフト

## タイトル

マイクロアーキテクチャを考慮したスピン待機のPAUSE命令最適化

---

## スライド2: 背景① — ロック競合とspin-wait

マルチコア環境では、複数スレッドが共有資源（バッファ、ログ等）に同時アクセスする際にロック競合が不可避となる。競合時の待機戦略には大きく2つある。

**OS wait（futex）**
- カーネルに制御を渡してスレッドをスリープさせる
- wake-up レイテンシが ~数μs（スケジューラの粒度に依存）
- ロック保持時間がそれより短ければオーバーヘッドが支配的になる

**spin-wait（ビジーウェイト）**
- ロックが解放されるまでポーリングを繰り返す
- wake-up レイテンシがなく、短時間競合には高効率
- ただし解放を見逃さないためCPUを占有し続ける

現代のロック実装では **「まずspinで待ち、タイムアウト後にOS waitへ移行」する2段階方式** が標準となっている（MySQL InnoDB、Linux pthread adaptive mutex 等）。

---

## スライド3: 背景② — tight spinの問題とPAUSE命令の役割

単純なtight spinループ（`while (!trylock());`）には以下の問題がある。

**問題①: Memory Order Buffer (MOB) の誤フラッシュ**
ロック変数の繰り返しロードは、プロセッサがメモリ順序違反を誤検出してパイプラインフラッシュを引き起こす。

**問題②: キャッシュコヒーレンストラフィックの増大**
すべてのコアが同一キャッシュラインを読み続けることでバスに大量のコヒーレンスメッセージが発生し、ロックホルダーのコアも影響を受ける。

これを解決するのが **x86 PAUSE命令**（`rep; nop`）だ。Intel SDM は spin-wait loop 内での PAUSE 使用を明示的に推奨しており、以下の効果がある：

- パイプラインに「spin中」というヒントを与え MOB フラッシュを抑制
- ロードリピート間隔を広げ、コヒーレンストラフィックを削減
- HT sibling コアへの干渉を緩和

**主要OSS実装での採用：**

| 実装 | PAUSE の使われ方 |
|---|---|
| Linux kernel | `cpu_relax()` = PAUSE、全スピンロックで使用 |
| MySQL InnoDB | `ut_delay(delay × multiplier)` 内で `UT_RELAX_CPU()` = PAUSE |
| glibc pthread | adaptive mutex のスピンフェーズ |
| memcached | `pthread_mutex` スピンパス |

```c
// MySQL: storage/innobase/ut/ut0ut.cc
unsigned long ut_delay(unsigned long delay) {
    for (unsigned long i = 0; i < delay * srv_spin_wait_pause_multiplier; i++) {
        UT_RELAX_CPU();  // = rep; nop = PAUSE命令
        j += i;
    }
}
```

---

## スライド4: 問題提起 — PAUSEレイテンシはアーキテクチャ依存なのに設定は固定

PAUSE命令のレイテンシはマイクロアーキテクチャによって大きく異なる。

| アーキテクチャ | PAUSE レイテンシ | multiplier デフォルト |
|---|---|---|
| Ivy Bridge (c8220) | ~15 cy | 50（固定） |
| Broadwell (xl170) | ~12 cy | 50（固定） |
| Skylake (c220g5 / ann) | **~140 cy** | 50（固定） |
| Ice Lake (sm110) | ~50 cy | 50（固定） |
| Emerald Rapids (c6620) | ~37 cy | 50（固定） |

MySQLの `innodb_spin_wait_pause_multiplier`（デフォルト=50）は全アーキテクチャで共通設定だ。
Skylake では 1 spin iteration あたり `50 × 140cy = 7,000cy ≈ 2.5μs` を消費するのに対し、
Broadwell では `50 × 12cy = 600cy ≈ 0.2μs` に過ぎない。
**同じ設定でも実際のスピンコストは12倍異なる。**

→ **アーキテクチャごとに最適なPAUSE回数があるはず**、という仮説を立て、実験で検証した。

---

## スライド5: 実験① — simple_spinlock: 最適multiplierはアーキテクチャ依存

MySQLの `ut_delay` を模倣した最小スピンロック実装（`simple_spinlock.c`）を用いて、
PAUSE回数（multiplier）とスループットの関係をアーキテクチャ別に計測した。

**実験設定：**
- スレッド数：8 / 16 / 32
- multiplier：0 〜 50,000
- クリティカルセクション長（work_ns）：0 / 100 / 500 / 1000 / 2000 / 5000 ns
- 計測：スループット（ロック取得回数/秒）

**図: `simple_mysql/result/per_server/skylake_ann_throughput_grouped.png`**
**図: `simple_mysql/result/per_server/emerald_c6620_throughput_grouped.png`**
**図: `simple_mysql/result/per_server/broadwell_xl170_throughput_grouped.png`**

**観察：**
- **Skylake ann（PAUSE ~142cy）**: ピークが低いmultiplier（数十〜数百）に現れ、それ以上では急落。PAUSEが重いため大量のPAUSEはスピンコストを過大にする。
- **Emerald Rapids（PAUSE ~37cy）**: ピークがより高いmultiplier（数百〜数千）に現れ、緩やかに最適値へ向かう。PAUSEが軽いため多くのPAUSEを積んでもスループットが維持できる。
- **Broadwell（PAUSE ~12cy）**: Emerald Rapidsと同様、高multiplierまで耐性がある。

→ **最適なmultiplierはアーキテクチャのPAUSEレイテンシに逆比例する。**
PAUSEが重いSkylakeほど少ないPAUSEが最適になる。

---

## スライド6: 実験② — memcached: 同様の傾向を実際のキャッシュサーバで確認

実際のワークロードとしてmemcachedを用い、スピン待機のPAUSE回数（pause_per_round）を
変化させたときのレイテンシとQPSをアーキテクチャ別に計測した。

**実験設定：**
- ベンチマーク：mutilate（mc=4t, T4, c1, d32）
- pause_per_round (N)：0 / 2 / 4 / 10 / 30 / 100 / 200

**図: `experiment/results/utdelay_arch_r_boxplot.png`**

**観察：**
- **Skylake ann（PAUSE ~142cy）**: N=0〜2付近でレイテンシ最小。N=100以降で劣化が著しい（p99が300μs超）。
- **Broadwell（PAUSE ~12cy）**: N=30付近が最適。N=200でも大きな劣化なし。
- **Emerald Rapids（PAUSE ~37cy）**: N=30前後が最適。Skylakeより高いNに耐性がある。

**図: `experiment/results/utdelay_arch_normalized.png`**

**観察：**
- Skylake ann は N=0からすでにQPSが低く、N増加とともに急落する唯一のアーキテクチャ。
- Broadwell / Emerald / Ivy Bridge は N=25〜50付近でQPSが最大になり、その後緩やかに低下。
- **アーキテクチャごとに最適なNが明確に異なる**ことが示された。

simple_spinlockと同じ傾向：**PAUSEが重いSkylakeほど少ないPAUSEが最適。**

---

## スライド7: MySQL実験 — 実際のDBで検証を試みたが大幅改善が得られなかった

simple_spinlock / memcached で得られた知見（「Skylakeでは少ないPAUSEが最適」）を
MySQL InnoDBで検証した。`innodb_spin_wait_pause_multiplier` を 0〜100 の範囲でスイープし、
TPSへの影響を計測した。

**実験設定：**
- サーバ：Skylake-c220g5（PAUSE ~140cy）
- ワークロード：sysbench oltp_read_write（tables=8, size=100K）
- スレッド数：8
- multiplier：0, 5, 10, 25, 50（default）, 75, 100

**図: `mysql-workspace/experiments/results/large-multiplier/skylake_c220g5_tps_vs_multiplier.png`**

**観察：**
- multiplierを0〜100まで変化させてもTPSの変化は誤差範囲内（±3%程度）
- simple_spinlock / memcachedで見られた「低multiplierで改善」という傾向が現れない
- **グローバルなmultiplier変更ではMySQL全体のTPSを大幅に改善できなかった**

※ 実験環境（コア数・sysbench配置）に問題がある可能性があり、再実験が必要。

---

## スライド8: なぜ改善しなかったのか — ロックごとに最適な待機戦略が異なる（今後の課題）

MySQLでmultiplierを変えても改善しなかった理由を調査するために、
performance_schema から各ロックの取得回数・平均待機時間を計測した。

**図: `mysql-workspace/experiments/results/baseline/lock_characteristics.png`**

**観察：**
取得回数・平均待機時間ともに **桁違いの差** がある。

| ロック | 取得回数/run | 平均待機時間 | 特性 |
|---|---|---|---|
| `log_files_mutex` | 5,700 | 0.69 ms | 長待ち・低頻度 |
| `log_writer_mutex` | 11,600 | 0.18 ms | 長待ち・低頻度 |
| `lock_sys_page_mutex` | 1,200,000 | 0.003 ms | 中間 |
| `hash_table_locks` | 17,900,000 | 0.0002 ms | 超短待ち・高頻度 |
| `trx_mutex` | 30,800,000 | 0.0001 ms | 超短待ち・高頻度 |

これらすべてが **同一の `ut_delay` メカニズム**（同一の `multiplier`）で制御されている。

**問題の本質：**
あるロックにとって最適なmultiplier（小さい値）は、別のロックにとって最悪の設定になる可能性がある。
グローバルにmultiplierを下げると一部のロックは改善するが別のロックは悪化し、
結果として全体TPSへの影響が打ち消し合う。

→ **ロック種別ごとに独立したPAUSE制御が必要**というのが今後の課題。

---

## スライド9: まとめと今後の課題

**得られた知見：**

1. PAUSEレイテンシはアーキテクチャ依存（Broadwell ~12cy vs Skylake ~140cy）
2. **simple_spinlock / memcached**: 最適なPAUSE回数はアーキテクチャごとに異なることを確認。Skylakeでは少ないPAUSEが最適。
3. **MySQL**: グローバルなmultiplier変更ではTPSへの有意な改善が見られなかった。

**今後の課題：**

- MySQL実験環境の整備と再計測（コア数・sysbench配置の見直し）
- 「なぜ改善しないか」の仮説（ロックごとに最適戦略が逆）の定量的検証
- ロック種別ごとのPAUSE制御メカニズムの設計・実装
- より多くのアーキテクチャへの拡張（ARM系との比較等）
