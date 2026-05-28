#!/bin/bash
# ============================================================
# 测试项：顺序读写 (Sequential I/O)
# 场景：大文件连续读写，测试吞吐量极限
# 关注指标：带宽 (BW)，顺序读/写速度
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  顺序读写测试 (Sequential I/O)"
echo "========================================"
reset_device
echo "  [注意] 使用 $EMMC_DEV 做原始设备测试"
echo "  如果该设备有分区表，写入操作会破坏数据!"
echo ""

SIZE="1G"
BLOCK_SIZES=("128k" "512k" "1m" "4m")
RESULTS=()

# --- 裸设备测试 ---
run_raw() {
  local bs=$1 rw=$2 label=$3
  local output="${RESULT_DIR}/seq_${label}_bs${bs}.json"
  echo "  裸设备 - ${label} (bs=${bs})..."

  fio --filename="$EMMC_DEV" \
      --direct=1 \
      --rw=$rw \
      --bs=$bs \
      --size=$SIZE \
      --iodepth=64 \
      --numjobs=1 \
      --ioengine=libaio \
      --runtime=$RUNTIME \
      --time_based \
      --ramp_time=$RAMP_TIME \
      --name=seq_${label}_bs${bs} \
      --output="$output" \
      --output-format=json 2>/dev/null

  RESULTS+=("$(parse_fio_result "$output" "裸设备-${label}-${bs}")")
}

# --- 文件系统测试 ---
run_fs() {
  local bs=$1 rw=$2 label=$3
  local output="${RESULT_DIR}/seq_fs_${label}_bs${bs}.json"
  local testfile="${MOUNT_POINT}/seq_test_${label}"

  echo "  文件系统 - ${label} (bs=${bs})..."

  fio --filename="$testfile" \
      --size=$SIZE \
      --direct=1 \
      --rw=$rw \
      --bs=$bs \
      --iodepth=64 \
      --numjobs=1 \
      --ioengine=libaio \
      --runtime=$RUNTIME \
      --time_based \
      --ramp_time=$RAMP_TIME \
      --fallocate=posix \
      --name=seq_fs_${label}_bs${bs} \
      --output="$output" \
      --output-format=json 2>/dev/null

  RESULTS+=("$(parse_fio_result "$output" "文件系统-${label}-${bs}")")
  rm -f "$testfile"
}

# --- 预条件（可选）---
# 默认跳过全盘预条件（避免破坏分区表）
# 如需全盘预条件，设置 SKIP_PRECONDITION=0
SKIP_PRECONDITION=1
precondition() {
  if [ "$SKIP_PRECONDITION" = "0" ]; then
    echo "  [WARN] 全盘预条件写入，所有数据将被覆盖!"
    fio --filename="$EMMC_DEV" \
        --direct=1 \
        --rw=write \
        --bs=1m \
        --size=100% \
        --iodepth=32 \
        --ioengine=libaio \
        --name=precondition \
        --output=/dev/null 2>/dev/null
    echo "  [预条件] 完成"
  else
    echo "  [预条件] 跳过（设置 SKIP_PRECONDITION=0 以启用）"
  fi
}

precondition

echo ""
echo "--- 裸设备顺序测试 ---"
for bs in "${BLOCK_SIZES[@]}"; do
  run_raw "$bs" "read" "read"
  run_raw "$bs" "write" "write"
  run_raw "$bs" "rw" "rw_70_30"
done

echo ""
echo "--- 文件系统顺序测试 ---"
if mountpoint -q "$MOUNT_POINT"; then
  for bs in "${BLOCK_SIZES[@]}"; do
    run_fs "$bs" "read" "read"
    run_fs "$bs" "write" "write"
  done
else
  echo "  [跳过] $MOUNT_POINT 未挂载"
fi

echo ""
echo "====== 顺序读写测试结果 ======"
for r in "${RESULTS[@]}"; do
  echo "  $r"
done

append_summary "顺序读写" "${RESULTS[@]}"
