#!/bin/bash
# ============================================================
# 测试项：压力测试 (Stress Test)
# 场景：高并发大负载，测试 eMMC 极限能力与稳定性
# 关注指标：最高IOPS, 延迟抖动(99%/99.9%), 稳定性
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  压力测试 (Stress Test)"
echo "========================================"
reset_device

SIZE="2G"
RUNTIME=120
RESULTS=()

stress_scenarios() {
  local label=$1 rw=$2 bs=$3 iodepth=$4 numjobs=$5
  local output="${RESULT_DIR}/stress_${label}.json"

  echo "  场景: ${label} (bs=${bs} qd=${iodepth} jobs=${numjobs})..."

  fio --filename="$EMMC_DEV" \
      --direct=1 \
      --rw=$rw \
      --bs=$bs \
      --size=$SIZE \
      --iodepth=$iodepth \
      --numjobs=$numjobs \
      --ioengine=libaio \
      --group_reporting \
      --runtime=$RUNTIME \
      --time_based \
      --ramp_time=$RAMP_TIME \
      --name=stress_${label} \
      --write_lat_log="${LOG_DIR}/stress_${label}" \
      --output="$output" \
      --output-format=json 2>/dev/null

  RESULTS+=("$(parse_fio_result "$output" "压力-${label}")")

  # 延迟分布分析
  if [ -f "$output" ]; then
    python3 -c "
import json
d = json.load(open('$output'))
job = d.get('jobs', [{}])[0]
for rw in ['read', 'write']:
    clat = job.get(rw, {}).get('clat_ns', {}).get('percentile', {})
    if clat:
        print(f'  {rw}延迟(usec): P50={clat.get(\"50.000000\",0)/1000:.1f} P90={clat.get(\"90.000000\",0)/1000:.1f} P99={clat.get(\"99.000000\",0)/1000:.1f} P99.9={clat.get(\"99.900000\",0)/1000:.1f} P99.99={clat.get(\"99.990000\",0)/1000:.1f}')
" 2>/dev/null || true
  fi
}

echo ""
echo "--- 高并发随机读写 ---"
stress_scenarios "randread_4k_qd32" "randread" "4k" 32 1
stress_scenarios "randwrite_4k_qd32" "randwrite" "4k" 32 1
stress_scenarios "randrw_4k_qd16" "randrw" "4k" 16 4

echo ""
echo "--- 高并发顺序 ---"
stress_scenarios "seqread_1m_qd64" "read" "1m" 64 1
stress_scenarios "seqwrite_1m_qd64" "write" "1m" 64 1

echo ""
echo "--- 多Job并发 ---"
stress_scenarios "multijob_randread_4k_qd8_j4" "randread" "4k" 8 4
stress_scenarios "multijob_seqwrite_1m_qd16_j4" "write" "1m" 16 4

echo ""
echo "====== 压力测试结果 ======"
for r in "${RESULTS[@]}"; do
  echo "  $r"
done

append_summary "压力测试" "${RESULTS[@]}"
