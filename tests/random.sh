#!/bin/bash
# ============================================================
# 测试项：随机读写 (Random I/O)
# 场景：小文件随机读写，模拟系统盘/APP随机访问
# 关注指标：IOPS, 平均延迟
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  随机读写测试 (Random I/O)"
echo "========================================"
reset_device

SIZE="1G"
BLOCK_SIZES=("4k" "8k" "16k" "64k")
IODEPTHS=(1 2 4 8 16 32)
RESULTS=()

run_raw() {
  local bs=$1 iodepth=$2 rw=$3 label=$4
  local output="${RESULT_DIR}/rand_${label}_bs${bs}_qd${iodepth}.json"

  echo "  裸设备 - ${label} (bs=${bs} iodepth=${iodepth})..."

  fio --filename="$EMMC_DEV" \
      --direct=1 \
      --rw=$rw \
      --bs=$bs \
      --size=$SIZE \
      --iodepth=$iodepth \
      --numjobs=1 \
      --ioengine=libaio \
      --runtime=$RUNTIME \
      --time_based \
      --ramp_time=$RAMP_TIME \
      --random_distribution=random \
      --name=rand_${label}_bs${bs}_qd${iodepth} \
      --output="$output" \
      --output-format=json 2>/dev/null

  RESULTS+=("$(parse_fio_result "$output" "随机${label}-${bs}-QD${iodepth}")")
}

run_fs() {
  local bs=$1 iodepth=$2 rw=$3 label=$4
  local output="${RESULT_DIR}/rand_fs_${label}_bs${bs}_qd${iodepth}.json"
  local testfile="${MOUNT_POINT}/rand_test_${label}"

  echo "  文件系统 - ${label} (bs=${bs} iodepth=${iodepth})..."

  fio --filename="$testfile" \
      --size=$SIZE \
      --direct=1 \
      --rw=$rw \
      --bs=$bs \
      --iodepth=$iodepth \
      --numjobs=1 \
      --ioengine=libaio \
      --runtime=$(($RUNTIME / 2)) \
      --time_based \
      --ramp_time=$RAMP_TIME \
      --random_distribution=random \
      --fallocate=posix \
      --name=rand_fs_${label}_bs${bs}_qd${iodepth} \
      --output="$output" \
      --output-format=json 2>/dev/null

  RESULTS+=("$(parse_fio_result "$output" "FS随机${label}-${bs}-QD${iodepth}")")
  rm -f "$testfile"
}

echo ""
echo "--- 裸设备随机读写（变块大小 + 变队列深度）---"
for bs in "${BLOCK_SIZES[@]}"; do
  for qd in "${IODEPTHS[@]}"; do
    run_raw "$bs" "$qd" "randread" "read"
    run_raw "$bs" "$qd" "randwrite" "write"
  done
done

echo ""
echo "--- 默认参数基准 ---"
# 4K QD=1 (单线程随机，最典型的手机/嵌入式场景)
run_raw "4k" "1" "randread" "read_baseline"
run_raw "4k" "1" "randwrite" "write_baseline"

echo ""
echo "--- 文件系统随机测试 ---"
if mountpoint -q "$MOUNT_POINT"; then
  run_fs "4k" "1" "randread" "read"
  run_fs "4k" "1" "randwrite" "write"
  run_fs "4k" "4" "randread" "read_qd4"
  run_fs "4k" "4" "randwrite" "write_qd4"
else
  echo "  [跳过] $MOUNT_POINT 未挂载"
fi

echo ""
echo "====== 随机读写测试结果 ======"
for r in "${RESULTS[@]}"; do
  echo "  $r"
done

append_summary "随机读写" "${RESULTS[@]}"
