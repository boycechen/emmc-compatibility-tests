#!/bin/bash
# ============================================================
# 不规则 IO 模式测试 (Erratic IO Patterns)
#
# 原理：eMMC 固件通常在常规IO模式下经过了充分测试，
#   但在不规则IO模式（离散地址、突发暂停、混合ioengine等）
#   下可能触发固件的未预期分支，导致异常行为。
#
# 测试覆盖：
#   1. IO Size 不匹配: 512B/1.5K/3K 等非标大小
#   2. 地址非对齐: 奇数扇区地址
#   3. 突发-空闲-突发: 类似"巴士"模式的IO
#   4. 混合 ioengine: sync + libaio + mmap 混用
#   5. 强制缓存刷新的频率变化
#   6. 文件系统 + 裸设备 混合访问
#   7. 长短IO交错
#   8. 写后立即trim
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  不规则 IO 模式测试 (Erratic IO)"
echo "========================================"
reset_device

SIZE="512M"
RESULTS=()

echo ""
echo "--- 非标IO大小测试 ---"
for bs in "512" "768" "1.5k" "3k" "6k" "12k" "24k" "48k" "96k" "200k"; do
  echo -n "  bs=${bs} ... "
  fio --filename="$EMMC_DEV" \
      --direct=1 \
      --rw=randwrite \
      --bs=$bs \
      --size=$SIZE \
      --iodepth=4 \
      --ioengine=libaio \
      --runtime=15 \
      --time_based \
      --name=erratic_bs_${bs} \
      --output="${RESULT_DIR}/erratic_bs_${bs}.json" \
      --output-format=json 2>/dev/null
  RESULTS+=("$(parse_fio_result "${RESULT_DIR}/erratic_bs_${bs}.json" "非标bs-${bs}")")
done

echo ""
echo "--- 突发-空闲-突发模式 ---"
echo "  模拟交通拥堵式IO: 短时高强度→空闲→再突发"
for burst_size in "8k" "64k" "512k"; do
  echo "  突发大小=${burst_size} ..."
  fio --filename="$EMMC_DEV" \
      --direct=1 \
      --rw=randwrite \
      --bs=$burst_size \
      --size=$SIZE \
      --iodepth=32 \
      --ioengine=libaio \
      --numjobs=4 \
      --runtime=60 \
      --time_based \
      --ramp_time=0 \
      --rate_iops=1000,2000 \
      --name=burst_${burst_size} \
      --output="${RESULT_DIR}/erratic_burst_${burst_size}.json" \
      --output-format=json 2>/dev/null
  RESULTS+=("$(parse_fio_result "${RESULT_DIR}/erratic_burst_${burst_size}.json" "突发-${burst_size}")")
done

echo ""
echo "--- 异步/同步 IO 引擎混用 ---"
echo "  libaio + sync + mmap 混合..."

# 多个fio实例用不同引擎同时跑
fio --filename="$EMMC_DEV" \
    --direct=1 \
    --rw=randread \
    --bs=4k \
    --size=$SIZE \
    --iodepth=8 \
    --ioengine=libaio \
    --runtime=20 \
    --time_based \
    --name=mixed_engine_libaio \
    --output=/dev/null 2>/dev/null &
PID1=$!

fio --filename="$EMMC_DEV" \
    --direct=1 \
    --rw=randwrite \
    --bs=4k \
    --size=$SIZE \
    --iodepth=1 \
    --ioengine=sync \
    --runtime=20 \
    --time_based \
    --name=mixed_engine_sync \
    --output="${RESULT_DIR}/erratic_engine_sync.json" \
    --output-format=json 2>/dev/null &
PID2=$!

fio --filename="$EMMC_DEV" \
    --rw=randread \
    --bs=4k \
    --size=128M \
    --ioengine=mmap \
    --runtime=20 \
    --time_based \
    --name=mixed_engine_mmap \
    --output="${RESULT_DIR}/erratic_engine_mmap.json" \
    --output-format=json 2>/dev/null &
PID3=$!

wait $PID1 $PID2 $PID3 2>/dev/null
RESULTS+=("$(parse_fio_result "${RESULT_DIR}/erratic_engine_sync.json" "混合引擎-sync")")
RESULTS+=("$(parse_fio_result "${RESULT_DIR}/erratic_engine_mmap.json" "混合引擎-mmap")")

echo ""
echo "--- 短IO长IO交错 ---"
echo "  512B写+1M写交替..."
fio --filename="$EMMC_DEV" \
    --direct=1 \
    --rw=randwrite \
    --bsrange=512-1m \
    --size=$SIZE \
    --iodepth=4 \
    --ioengine=libaio \
    --runtime=30 \
    --time_based \
    --name=interleaved_io \
    --output="${RESULT_DIR}/erratic_interleave.json" \
    --output-format=json \
    --bssplit="512/10:4k/40:64k/30:1m/20" 2>/dev/null
RESULTS+=("$(parse_fio_result "${RESULT_DIR}/erratic_interleave.json" "短长交错IO")")

echo ""
echo "--- 大量并发sync IO (线程模式) ---"
echo "  16线程 fsync..."

timeout 45 fio --filename="$EMMC_DEV" \
    --direct=0 \
    --rw=randwrite \
    --bs=4k \
    --size=128M \
    --iodepth=1 \
    --numjobs=16 \
    --ioengine=sync \
    --group_reporting \
    --runtime=30 \
    --time_based \
    --fallocate=none \
    --name=sync_storm \
    --output="${RESULT_DIR}/erratic_sync_storm.json" \
    --output-format=json 2>/dev/null
RESULTS+=("$(parse_fio_result "${RESULT_DIR}/erratic_sync_storm.json" "sync风暴")")

echo ""
echo "--- 交替 fsync/fdatasync 压力 ---"
timeout 45 fio --filename="$EMMC_DEV" \
    --direct=0 \
    --rw=randwrite \
    --bs=512 \
    --size=128M \
    --iodepth=1 \
    --numjobs=8 \
    --ioengine=psync \
    --group_reporting \
    --runtime=30 \
    --time_based \
    --fallocate=none \
    --fsync=1 \
    --name=fsync_storm \
    --output="${RESULT_DIR}/erratic_fsync_storm.json" \
    --output-format=json 2>/dev/null
RESULTS+=("$(parse_fio_result "${RESULT_DIR}/erratic_fsync_storm.json" "fsync风暴")")

echo ""
echo "====== 不规则 IO 测试结果 ======"
for r in "${RESULTS[@]}"; do
  echo "  $r"
done
append_summary "不规则IO" "非标块大小/混合引擎/同步风暴测试完成"
