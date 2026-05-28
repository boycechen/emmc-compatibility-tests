#!/bin/bash
# ============================================================
# 测试项：混合读写 (Mixed I/O)
# 场景：同时读写混合，模拟数据库/Web服务器等真实负载
# 关注指标：混合IOPS, 读写延迟互影响
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  混合读写测试 (Mixed I/O)"
echo "========================================"
reset_device

SIZE="1G"
RWMIXREADS=(30 50 70 90)
IODEPTHS=(1 4 16)
BS="4k"
RESULTS=()

run_mixed_raw() {
  local rwmix=$1 iodepth=$2
  local label="mixed_rw${rwmix}_qd${iodepth}"
  local output="${RESULT_DIR}/mixed_raw_${label}.json"

  echo "  裸设备 - 读${rwmix}%/写$((100 - rwmix))% QD=${iodepth}..."

  fio --filename="$EMMC_DEV" \
      --direct=1 \
      --rw=randrw \
      --rwmixread=$rwmix \
      --bs=$BS \
      --size=$SIZE \
      --iodepth=$iodepth \
      --numjobs=1 \
      --ioengine=libaio \
      --runtime=$RUNTIME \
      --time_based \
      --ramp_time=$RAMP_TIME \
      --random_distribution=random \
      --name=mixed_${label} \
      --output="$output" \
      --output-format=json 2>/dev/null

  RESULTS+=("$(parse_fio_result "$output" "混合R${rwmix}W$((100 - rwmix))-QD${iodepth}")")
}

run_mixed_fs() {
  local rwmix=$1
  local output="${RESULT_DIR}/mixed_fs_rw${rwmix}.json"
  local testfile="${MOUNT_POINT}/mixed_test"

  echo "  文件系统 - 读${rwmix}%/写$((100 - rwmix))%..."

  fio --filename="$testfile" \
      --size=$SIZE \
      --direct=1 \
      --rw=randrw \
      --rwmixread=$rwmix \
      --bs=$BS \
      --iodepth=4 \
      --numjobs=2 \
      --ioengine=libaio \
      --runtime=$(($RUNTIME / 2)) \
      --time_based \
      --ramp_time=$RAMP_TIME \
      --random_distribution=random \
      --fallocate=posix \
      --name=mixed_fs_rw${rwmix} \
      --output="$output" \
      --output-format=json 2>/dev/null

  RESULTS+=("$(parse_fio_result "$output" "FS混合R${rwmix}W$((100 - rwmix))")")
  rm -f "$testfile"
}

echo ""
echo "--- 裸设备混合读写（变读写比 + 变队列深度）---"
for rwmix in "${RWMIXREADS[@]}"; do
  for qd in "${IODEPTHS[@]}"; do
    run_mixed_raw "$rwmix" "$qd"
  done
done

echo ""
echo "--- 文件系统混合读写 ---"
if mountpoint -q "$MOUNT_POINT"; then
  for rwmix in "${RWMIXREADS[@]}"; do
    run_mixed_fs "$rwmix"
  done
else
  echo "  [跳过] $MOUNT_POINT 未挂载"
fi

echo ""
echo "====== 混合读写测试结果 ======"
for r in "${RESULTS[@]}"; do
  echo "  $r"
done

append_summary "混合读写" "${RESULTS[@]}"
