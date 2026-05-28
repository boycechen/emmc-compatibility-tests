#!/bin/bash
# ============================================================
# 测试项：延迟测试 (Latency Test)
# 场景：低队列深度下延迟分布，模拟交互式/实时应用
# 关注指标：P50/P90/P99/P99.9 延迟, 最大延迟
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  延迟测试 (Latency Test)"
echo "========================================"
reset_device

SIZE="512M"
BLOCK_SIZES=("512" "1k" "4k" "16k")
RESULTS=()

run_latency() {
  local bs=$1 rw=$2 label=$3
  local output="${RESULT_DIR}/latency_${label}_bs${bs}.json"

  echo "  ${label} (bs=${bs})..."

  fio --filename="$EMMC_DEV" \
      --direct=1 \
      --rw=$rw \
      --bs=$bs \
      --size=$SIZE \
      --iodepth=1 \
      --numjobs=1 \
      --ioengine=libaio \
      --runtime=30 \
      --time_based \
      --ramp_time=5 \
      --name=latency_${label}_bs${bs} \
      --output="$output" \
      --output-format=json \
      --lat_percentiles=1 2>/dev/null

  RESULTS+=("$(parse_fio_result "$output" "延迟-${label}-${bs}")")

  if [ -f "$output" ]; then
    python3 -c "
import json
d = json.load(open('$output'))
job = d.get('jobs', [{}])[0]
for rw in ['read', 'write']:
    clat = job.get(rw, {}).get('clat_ns', {}).get('percentile', {})
    slat = job.get(rw, {}).get('slat_ns', {}).get('percentile', {})
    lat = job.get(rw, {}).get('lat_ns', {}).get('percentile', {})
    if clat:
        print(f'  {rw}:')
        print(f'    P50={clat.get(\"50.000000\",0)/1000:.1f}us P90={clat.get(\"90.000000\",0)/1000:.1f}us P99={clat.get(\"99.000000\",0)/1000:.1f}us P99.9={clat.get(\"99.900000\",0)/1000:.1f}us')
        print(f'    P99.99={clat.get(\"99.990000\",0)/1000:.1f}us P99.999={clat.get(\"99.999000\",0)/1000:.1f}us')
        print(f'    max={job.get(rw,{}).get(\"clat_ns\",{}).get(\"max\",0)/1000:.1f}us')
" 2>/dev/null || true
  fi
}

echo ""
echo "--- 单队列深度延迟 (QD=1) ---"
for bs in "${BLOCK_SIZES[@]}"; do
  run_latency "$bs" "randread" "随机读"
  run_latency "$bs" "randwrite" "随机写"
done

echo ""
echo "--- 顺序访问延迟 ---"
for bs in "${BLOCK_SIZES[@]}"; do
  run_latency "$bs" "read" "顺序读"
  run_latency "$bs" "write" "顺序写"
done

echo ""
echo "--- 延迟稳定性测试 (长时采样) ---"
echo "  4K随机读 QD=1 持续120s..."

fio --filename="$EMMC_DEV" \
    --direct=1 \
    --rw=randread \
    --bs=4k \
    --size=1G \
    --iodepth=1 \
    --numjobs=1 \
    --ioengine=libaio \
    --runtime=120 \
    --time_based \
    --name=latency_long \
    --output="${RESULT_DIR}/latency_long.json" \
    --output-format=json \
    --lat_percentiles=1 \
    --write_lat_log="${LOG_DIR}/latency_long" 2>/dev/null

python3 -c "
import json
d = json.load(open('${RESULT_DIR}/latency_long.json'))
job = d.get('jobs', [{}])[0]
clat = job.get('read', {}).get('clat_ns', {}).get('percentile', {})
if clat:
    print(f'  QD=1 随机读 长时延迟分布:')
    print(f'    P50={clat.get(\"50.000000\",0)/1000:.1f}us P90={clat.get(\"90.000000\",0)/1000:.1f}us')
    print(f'    P99={clat.get(\"99.000000\",0)/1000:.1f}us P99.9={clat.get(\"99.900000\",0)/1000:.1f}us')
    print(f'    P99.99={clat.get(\"99.990000\",0)/1000:.1f}us P99.999={clat.get(\"99.999000\",0)/1000:.1f}us')
    print(f'    max={job.get(\"read\",{}).get(\"clat_ns\",{}).get(\"max\",0)/1000:.1f}us')
    # 延迟一致性评价
    p50 = clat.get('50.000000', 1)
    p99 = clat.get('99.000000', 1)
    ratio = p99 / p50 if p50 > 0 else 0
    print(f'    P99/P50={ratio:.1f}x (一致性指标, <10x 良好, <5x 优秀)')
"

echo ""
echo "====== 延迟测试结果 ======"
for r in "${RESULTS[@]}"; do
  echo "  $r"
done

append_summary "延迟测试" "${RESULTS[@]}"
