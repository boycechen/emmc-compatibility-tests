#!/bin/bash
# ============================================================
# 测试项：全盘填充测试 (Full Disk Fill)
# 场景：逐步写满全盘，观察 GC 行为及性能拐点
# 关注指标：填充过程中的性能变化, 可用容量
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  全盘填充测试 (Full Disk Fill)"
echo "========================================"

# 获取设备总容量
DEV_SIZE=$(blockdev --getsize64 "$EMMC_DEV" 2>/dev/null)
if [ -z "$DEV_SIZE" ] || [ "$DEV_SIZE" -eq 0 ]; then
  echo "[ERROR] 无法获取设备大小"
  exit 1
fi
DEV_SIZE_MB=$((DEV_SIZE / 1048576))
DEV_SIZE_GB=$((DEV_SIZE_MB / 1024))
echo "  设备容量: ${DEV_SIZE_GB}GB"

# 填充阶段: 按百分比逐步填充
FILL_STEPS=(10 25 50 75 90 95 99)
RESULTS=()

# 性能测试偏移量（设备尾部 - 512MB，不低于0）
PERF_OFFSET=$((DEV_SIZE - 512 * 1048576))
[ "$PERF_OFFSET" -lt 0 ] && PERF_OFFSET=0

echo ""
echo "--- 逐步填充测试 ---"

prev_offset=0
for step in "${FILL_STEPS[@]}"; do
  step_offset=$((DEV_SIZE * step / 100))
  write_size=$((step_offset - prev_offset))

  # 向下取整到 MiB，避免 dd 的 bs=1M 截断问题
  write_bytes=$((write_size / 1048576 * 1048576))
  seek_mb=$((prev_offset / 1048576))

  echo "  填充至 ${step}% (写入 $((write_bytes / 1048576))MiB)..."

  if [ "$write_bytes" -gt 0 ]; then
    dd if=/dev/urandom of="$EMMC_DEV" bs=1M count=$((write_bytes / 1048576)) \
       seek=$seek_mb oflag=direct status=none 2>/dev/null || {
      echo "  [ERROR] dd 写入失败! 设备可能已满或出现错误"
      break
    }
  fi

  # 在每个填充点测一次随机写性能
  fio --filename="$EMMC_DEV" \
      --direct=1 \
      --rw=randwrite \
      --bs=4k \
      --size=256M \
      --offset=$PERF_OFFSET \
      --iodepth=1 \
      --ioengine=libaio \
      --runtime=20 \
      --time_based \
      --name=fill_perf_${step}pct \
      --output="${RESULT_DIR}/fill_${step}pct.json" \
      --output-format=json 2>/dev/null || true

  RESULTS+=("$(parse_fio_result "${RESULT_DIR}/fill_${step}pct.json" "填充${step}%")")
  prev_offset=$step_offset
done

echo ""
echo "--- 全盘写满后性能 ---"
fio --filename="$EMMC_DEV" \
    --direct=1 \
    --rw=randwrite \
    --bs=4k \
    --size=256M \
    --offset=$PERF_OFFSET \
    --iodepth=1 \
    --ioengine=libaio \
    --runtime=20 \
    --time_based \
    --name=fill_full \
    --output="${RESULT_DIR}/fill_full.json" \
    --output-format=json 2>/dev/null || true

RESULTS+=("$(parse_fio_result "${RESULT_DIR}/fill_full.json" "100%填充后")")

echo ""
echo "--- 性能拐点分析 ---"
python3 -c "
import json, glob, os

results = []
for f in sorted(glob.glob('${RESULT_DIR}/fill_*.json')):
    step = os.path.basename(f).replace('fill_','').replace('.json','')
    try:
        d = json.load(open(f))
        iops = d.get('jobs',[{}])[0].get('write',{}).get('iops',0)
        bw = d.get('jobs',[{}])[0].get('write',{}).get('bw',0)
        results.append((step, iops, bw))
    except:
        pass

print(f'  {\"填充%\":>8} {\"IOPS\":>8} {\"BW(KB/s)\":>10}')
print(f'  {\"-\"*28}')
for step, iops, bw in results:
    print(f'  {step:>8} {iops:>8} {bw:>10}')

if len(results) >= 3:
    first_iops = results[0][1]
    if first_iops > 0:
      for step, iops, bw in results[1:]:
          drop = (1 - iops/first_iops) * 100
          if drop > 30:
              print(f'  [注意] 在 {step} 处出现性能拐点，降幅 {drop:.0f}%')
"

echo ""
echo "====== 全盘填充测试结果 ======"
for r in "${RESULTS[@]}"; do
  echo "  $r"
done

append_summary "全盘填充" "${RESULTS[@]}"
