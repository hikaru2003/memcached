# pause_d32 sweep / t=4 / mutilate -T 4 -c 1 -d 32 -r 1 -u 0.5 / n=5
# total_conns=4
# master baseline: QPS=692503.0  r_avg=us  r_p99=us  w_avg=us  w_p99=us

| label | mean_QPS | median_QPS | stddev_QPS | cv_pct | r_avg_us | r_p99_us | w_avg_us | w_p99_us | gain_vs_master% | n |
|---|---|---|---|---|---|---|---|---|---|---|
| master_baseline | 692503.0 | 692611.4 | 414.6 | 0.06 |  |  |  |  | +0.0% | 5 |
| pause_0 | 686762.1 | 687224.1 | 741.1 | 0.11 |  |  |  |  | -0.8% | 5 |
| pause_100 | 906329.7 | 906617.0 | 1356.5 | 0.15 |  |  |  |  | +30.9% | 5 |
| pause_200 | 909105.4 | 909801.9 | 2511.8 | 0.28 |  |  |  |  | +31.3% | 5 |
| pause_500 | 900959.6 | 900956.2 | 754.9 | 0.08 |  |  |  |  | +30.1% | 5 |
| pause_1000 | 894711.9 | 895431.6 | 1933.9 | 0.22 |  |  |  |  | +29.2% | 5 |
