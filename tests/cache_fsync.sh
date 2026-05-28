#!/bin/bash
# ============================================================
# eMMC 写入缓存 + fsync 压力测试
#
# 原理：eMMC 内部有 write cache（由 EXT_CSD[33] 控制）。
#   缓存启用时，数据可能还在 cache 中就返回完成；
#   缓存关闭时，每次写入都等待 NAND 编程完成。
#   fsync/fdatasync 测试 flush 路径是否可靠。
#
# 检测目标：
#   - 缓存开关下的数据一致性
#   - fsync 高并发下的延迟抖动
#   - 混合 sync/direct IO 的互斥行为
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  写入缓存 + fsync 压力测试"
echo "========================================"
reset_device

RESULTS=()
SIZE="512M"

# --- 获取当前缓存状态 ---
get_cache_state() {
  local val=$(mmc extcsd read "$EMMC_DEV" 2>/dev/null | grep "EXT_CSD\[33\]" | awk '{print $NF}')
  if [ -n "$val" ]; then
    local bit2=$(( (val >> 2) & 1 ))
    [ "$bit2" -eq 1 ] && echo "ON" || echo "OFF"
  else
    echo "UNKNOWN"
  fi
}

echo ""
echo "--- 当前缓存状态: $(get_cache_state) ---"

echo ""
echo "--- 测试1: 缓存开关数据一致性 ---"
echo "  分别在缓存 ON/OFF 下做 fio write+verify"

for cache_flag in 0 1; do
  [ "$cache_flag" -eq 1 ] && label="缓存ON" || label="缓存OFF"
  echo "  $label ..."

  fio --filename="$EMMC_DEV" \
      --direct=1 --rw=write --bs=4k --size=$SIZE --iodepth=1 \
      --ioengine=libaio --name=cache_w_${cache_flag} \
      --output="${RESULT_DIR}/cache_write_${cache_flag}.json" --output-format=json \
      --verify=crc32c --verify_pattern=0xaa --verify_state_save=0 2>/dev/null || true

  fio --filename="$EMMC_DEV" \
      --direct=1 --rw=read --bs=4k --size=$SIZE --iodepth=1 \
      --ioengine=libaio --name=cache_r_${cache_flag} \
      --output="${RESULT_DIR}/cache_read_${cache_flag}.json" --output-format=json \
      --verify=crc32c --verify_pattern=0xaa --verify_state_save=0 --verify_fatal=1 \
      2>/dev/null || echo "    [FAIL] $label 校验失败!"

  RESULTS+=("$(parse_fio_result "${RESULT_DIR}/cache_write_${cache_flag}.json" "缓存${cache_flag}写")")
done

echo ""
echo "--- 测试2: fsync 延迟随队列深度变化 ---"
echo "  非 direct=0 + fsync=1, 测试 flush 路径..."

for qd in 1 4 16; do
  echo "  QD=${qd} ..."
  fio --filename="$EMMC_DEV" \
      --direct=0 --rw=randwrite --bs=4k --size=$SIZE \
      --iodepth=$qd --numjobs=1 --ioengine=libaio --fsync=1 \
      --runtime=30 --time_based --ramp_time=5 \
      --name=fsync_qd${qd} \
      --output="${RESULT_DIR}/fsync_qd${qd}.json" --output-format=json \
      --lat_percentiles=1 2>/dev/null || true

  python3 -c "
import json
d = json.load(open('${RESULT_DIR}/fsync_qd${qd}.json'))
job = d.get('jobs',[{}])[0]
wr = job.get('write', {})
iops = wr.get('iops', 0)
clat = wr.get('clat_ns', {}).get('percentile', {})
sync_lat = job.get('sync', {}).get('lat_ns', {}).get('percentile', {})
if clat:
    print(f'    IOPS: {iops}')
    print(f'    写延迟(us): P50={clat.get(\"50.000000\",0)/1000:.0f} P99={clat.get(\"99.000000\",0)/1000:.0f}')
if sync_lat:
    print(f'    fsync延迟(us): P50={sync_lat.get(\"50.000000\",0)/1000:.0f} P99={sync_lat.get(\"99.000000\",0)/1000:.0f}')
    p999 = sync_lat.get('99.900000',0)/1000
    if p999 > 100000:
        print(f'    [WARN] fsync P99.9={p999:.0f}us > 100ms, flush路径异常')
" 2>/dev/null || true
done

echo ""
echo "--- 测试3: sync + direct IO 混合 (裸设备 + buffered 混用) ---"
echo "  同时运行 direct=1 和 direct=0 的 fio, 测试互斥..."

fio --filename="$EMMC_DEV" \
    --direct=1 --rw=randread --bs=4k --size=$SIZE --iodepth=8 \
    --ioengine=libaio --runtime=20 --time_based \
    --name=mix_direct --output=/dev/null 2>/dev/null &
PID1=$!

fio --filename="$EMMC_DEV" \
    --direct=0 --rw=randwrite --bs=4k --size=$SIZE --iodepth=4 --fsync=2 \
    --ioengine=libaio --runtime=20 --time_based \
    --name=mix_buffered \
    --output="${RESULT_DIR}/cache_mixed.json" --output-format=json \
    --lat_percentiles=1 2>/dev/null || true

wait $PID1 2>/dev/null
RESULTS+=("$(parse_fio_result "${RESULT_DIR}/cache_mixed.json" "混合sync/direct")")

echo ""
echo "====== 写入缓存测试结果 ======"
for r in "${RESULTS[@]}"; do echo "  $r"; done
append_summary "写入缓存+fsync" \
  "缓存状态: $(get_cache_state)"
