#!/bin/bash
# ============================================================
# 测试项：稳定态测试 (Steady State)
# 场景：长时间持续写入，观察性能衰减曲线
# 关注指标：随时间变化的带宽/IOPS, 垃圾回收触发点
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  稳定态测试 (Steady State)"
echo "========================================"

RUNTIME=600
SIZE="100%"
RESULTS=()

echo ""
echo "--- 长时间持续随机写入 ---"
echo "  持续写 ${RUNTIME}s, 每30秒记录一次性能..."

fio --filename="$EMMC_DEV" \
    --direct=1 \
    --rw=randwrite \
    --bs=4k \
    --size=$SIZE \
    --iodepth=16 \
    --numjobs=1 \
    --ioengine=libaio \
    --runtime=$RUNTIME \
    --time_based \
    --ramp_time=30 \
    --name=steady_randwrite \
    --write_iops_log="${LOG_DIR}/steady_iops" \
    --write_bw_log="${LOG_DIR}/steady_bw" \
    --output="${RESULT_DIR}/steady_randwrite.json" \
    --output-format=json 2>/dev/null

RESULTS+=("$(parse_fio_result "${RESULT_DIR}/steady_randwrite.json" "稳定态-随机写")")

echo ""
echo "--- 长时间混合读写 ---"
fio --filename="$EMMC_DEV" \
    --direct=1 \
    --rw=randrw \
    --rwmixread=50 \
    --bs=4k \
    --size=$SIZE \
    --iodepth=8 \
    --numjobs=2 \
    --ioengine=libaio \
    --group_reporting \
    --runtime=$RUNTIME \
    --time_based \
    --ramp_time=30 \
    --name=steady_randrw \
    --write_iops_log="${LOG_DIR}/steady_rw_iops" \
    --write_bw_log="${LOG_DIR}/steady_rw_bw" \
    --output="${RESULT_DIR}/steady_randrw.json" \
    --output-format=json 2>/dev/null

RESULTS+=("$(parse_fio_result "${RESULT_DIR}/steady_randrw.json" "稳定态-混合读写")")

# --- 性能衰减分析 ---
echo ""
echo "--- 性能衰减分析 ---"
if [ -f "${LOG_DIR}/steady_iops.log" ]; then
  python3 -c "
import csv
with open('${LOG_DIR}/steady_iops.log') as f:
    lines = f.readlines()
# fio iops log: time(msec), value, dir(0=read,1=write), blocksize
write_iops = [(int(l.split(',')[0])/1000, int(l.split(',')[1])) for l in lines if int(l.split(',')[2]) == 1]
if write_iops:
    n = len(write_iops)
    half = n // 3
    first_third = [v for _, v in write_iops[:half]]
    last_third = [v for _, v in write_iops[-half:]]
    avg_first = sum(first_third)/len(first_third) if first_third else 0
    avg_last = sum(last_third)/len(last_third) if last_third else 0
    print(f'  IOPS: 前1/3平均={avg_first:.0f}, 后1/3平均={avg_last:.0f}')
    if avg_first > 0:
        decay = (1 - avg_last/avg_first) * 100
        print(f'  性能衰减: {decay:.1f}%')
        if decay > 20:
            print(f'  [警告] 性能衰减超过20%，可能存在过热或GC问题')
"
fi

echo ""
echo "====== 稳定态测试结果 ======"
for r in "${RESULTS[@]}"; do
  echo "  $r"
done

append_summary "稳定态" "${RESULTS[@]}"
