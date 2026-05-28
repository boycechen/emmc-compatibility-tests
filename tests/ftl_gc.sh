#!/bin/bash
# ============================================================
# FTL 垃圾回收压力测试
#
# 原理：FTL在后台做GC时会产生"写停顿"，本测试通过
#   "填充→随机写→填充→随机写"的交替模式，反复触发GC，
#   捕获GC导致的延迟尖峰(major latency spike)。
#
# 检测目标：GC延迟尖峰频率、幅度、对前台IO的影响程度
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  FTL 垃圾回收压力测试 (GC Stress)"
echo "========================================"

PART_SIZE=$(blockdev --getsize64 "$EMMC_DEV" 2>/dev/null)
GC_CHUNK=$((PART_SIZE / 4))  # 每次填充1/4盘
RESULTS=()

# --- 阶段1: 递增填充+随机写 (触发GC) ---
echo ""
echo "--- 阶段1: 递增填充 + 随机写，触发GC ---"
echo "  设备大小: $((PART_SIZE / 1073741824))GB, 每轮写入 1GB"

for round in 1 2 3 4; do
  echo "  第${round}轮: 顺序写脏区 + 随机写采样..."

  # Step A: 顺序写填盘 (触发GC)
  fio --filename="$EMMC_DEV" \
      --direct=1 \
      --rw=write \
      --bs=1m \
      --size=$((round * PART_SIZE / 4)) \
      --iodepth=16 \
      --ioengine=libaio \
      --name=gc_fill_r${round} \
      --output=/dev/null 2>/dev/null

  # Step B: 在脏盘上做随机写，捕获GC延迟
  fio --filename="$EMMC_DEV" \
      --direct=1 \
      --rw=randwrite \
      --bs=4k \
      --size=512M \
      --iodepth=8 \
      --numjobs=2 \
      --ioengine=libaio \
      --group_reporting \
      --runtime=60 \
      --time_based \
      --ramp_time=5 \
      --name=gc_sampling_r${round} \
      --output="${RESULT_DIR}/gc_round${round}.json" \
      --output-format=json \
      --write_lat_log="${LOG_DIR}/gc_lat_r${round}" \
      --log_avg_msec=100 2>/dev/null

  RESULTS+=("$(parse_fio_result "${RESULT_DIR}/gc_round${round}.json" "GC轮次${round}")")
done

# --- 阶段2: GC延迟尖峰捕获 ---
echo ""
echo "--- 阶段2: 长时GC延迟尖峰监测 ---"
echo "  持续5分钟随机写，100ms粒度记录延迟..."

fio --filename="$EMMC_DEV" \
    --direct=1 \
    --rw=randwrite \
    --bs=4k \
    --size=2G \
    --iodepth=32 \
    --numjobs=1 \
    --ioengine=libaio \
    --runtime=300 \
    --time_based \
    --ramp_time=10 \
    --name=gc_long \
    --output="${RESULT_DIR}/gc_long.json" \
    --output-format=json \
    --write_lat_log="${LOG_DIR}/gc_long_lat" \
    --log_avg_msec=100 2>/dev/null

RESULTS+=("$(parse_fio_result "${RESULT_DIR}/gc_long.json" "GC长时监测")")

# --- GC延迟尖峰分析 ---
echo ""
echo "--- GC延迟尖峰分析 ---"
if [ -f "${LOG_DIR}/gc_long_lat.log" ]; then
  python3 -c "
import csv, statistics

latencies = []
with open('${LOG_DIR}/gc_long_lat.log') as f:
    for line in f:
        parts = line.strip().split(',')
        if len(parts) >= 2 and parts[1]:
            try:
                latencies.append(int(parts[1]))
            except:
                pass

if latencies:
    lat_us = [l / 1000 for l in latencies]
    avg = statistics.mean(lat_us)
    median = statistics.median(lat_us)
    p95 = sorted(lat_us)[int(len(lat_us) * 0.95)]
    p99 = sorted(lat_us)[int(len(lat_us) * 0.99)]
    p999 = sorted(lat_us)[int(len(lat_us) * 0.999)]
    p9999 = sorted(lat_us)[int(len(lat_us) * 0.9999)]
    max_lat = max(lat_us)

    print(f'  采样点数: {len(lat_us)}')
    print(f'  平均延迟: {avg:.1f} us')
    print(f'  P50:  {median:.1f} us')
    print(f'  P95:  {p95:.1f} us')
    print(f'  P99:  {p99:.1f} us')
    print(f'  P99.9: {p999:.1f} us')
    print(f'  P99.99: {p9999:.1f} us')
    print(f'  最大延迟: {max_lat:.1f} us')

    # 检测GC尖峰: 延迟 > P99 * 5 的采样点
    threshold = median * 10
    spikes = [l for l in lat_us if l > threshold]
    spike_pct = len(spikes) / len(lat_us) * 100
    print(f'  GC尖峰(>{threshold:.0f}us)占比: {spike_pct:.3f}% ({len(spikes)}次)')

    if spike_pct > 1:
        print(f'  [FAIL] GC导致严重延迟尖峰，占比{spike_pct:.1f}%')
    elif max_lat > 50000:
        print(f'  [WARN] 最大延迟超过50ms，GC影响显著')
    else:
        print(f'  [PASS] GC控制良好，尖峰占比{spike_pct:.3f}%')

    # 检测延迟抖动(跑动中的P90/最小值的比值)
    sorted_us = sorted(lat_us)
    bottom10 = statistics.mean(sorted_us[:len(sorted_us)//10])
    top10 = statistics.mean(sorted_us[-len(sorted_us)//10:])
    jitter = top10 / bottom10 if bottom10 > 0 else 0
    print(f'  延迟抖动(上10%/下10%): {jitter:.1f}x')
    if jitter > 100:
        print(f'  [WARN] 延迟抖动极大(>{100}x)，FTL GC行为不稳定')
"
fi

echo ""
echo "====== FTL GC 测试结果 ======"
for r in "${RESULTS[@]}"; do
  echo "  $r"
done

append_summary "FTL_GC压力" "${RESULTS[@]}"
