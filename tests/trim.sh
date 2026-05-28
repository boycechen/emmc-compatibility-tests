#!/bin/bash
# ============================================================
# 测试项：TRIM/Discard 测试
# 场景：验证 TRIM 功能是否正常, TRIM 后性能恢复
# 关注指标：TRIM 前中后性能对比, 写放大因子
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  TRIM/Discard 测试"
echo "========================================"

SIZE="1G"
BS="4k"
RESULTS=()

# --- 检查设备是否支持 discard ---
check_trim_support() {
  local dev_name=$(basename "$EMMC_DEV")
  local discard_path="/sys/block/${dev_name}/queue/discard_granularity"
  if [ -f "$discard_path" ]; then
    local granularity=$(cat "$discard_path" 2>/dev/null)
    if [ "$granularity" -gt 0 ] 2>/dev/null; then
      echo "  [OK] 设备支持 discard (granularity=${granularity})"
      return 0
    fi
  fi
  echo "  [WARN] 设备不支持 discard，TRIM 测试可能无效"
  return 1
}

# --- 阶段1: 基线性能 ---
baseline_perf() {
  echo ""
  echo "--- 阶段1: 干净状态基线性能 ---"
  # 先做一次 discard 清理
  if check_trim_support; then
    echo "  执行 blkdiscard ..."
    blkdiscard "$EMMC_DEV" 2>/dev/null && echo "  blkdiscard 完成" || echo "  blkdiscard 失败"
    sleep 2
  fi

  fio --filename="$EMMC_DEV" \
      --direct=1 \
      --rw=randwrite \
      --bs=$BS \
      --size=$SIZE \
      --iodepth=1 \
      --numjobs=1 \
      --ioengine=libaio \
      --runtime=30 \
      --time_based \
      --name=trim_baseline \
      --output="${RESULT_DIR}/trim_baseline.json" \
      --output-format=json 2>/dev/null

  RESULTS+=("$(parse_fio_result "${RESULT_DIR}/trim_baseline.json" "TRIM前-基线")")
}

# --- 阶段2: 脏状态性能 ---
dirty_perf() {
  echo ""
  echo "--- 阶段2: 脏状态性能（全盘写脏后不TRIM）---"
  # 写脏全盘: 写入 2x 测试大小
  echo "  生成脏数据..."
  fio --filename="$EMMC_DEV" \
      --direct=1 \
      --rw=write \
      --bs=1m \
      --size=2G \
      --iodepth=16 \
      --ioengine=libaio \
      --name=dirty_fill \
      --output=/dev/null 2>/dev/null

  fio --filename="$EMMC_DEV" \
      --direct=1 \
      --rw=randwrite \
      --bs=$BS \
      --size=$SIZE \
      --iodepth=1 \
      --numjobs=1 \
      --ioengine=libaio \
      --runtime=30 \
      --time_based \
      --name=trim_dirty \
      --output="${RESULT_DIR}/trim_dirty.json" \
      --output-format=json 2>/dev/null

  RESULTS+=("$(parse_fio_result "${RESULT_DIR}/trim_dirty.json" "TRIM前-脏状态")")
}

# --- 阶段3: TRIM 后性能 ---
trim_perf() {
  echo ""
  echo "--- 阶段3: TRIM 后性能恢复 ---"
  if check_trim_support; then
    echo "  执行 blkdiscard ..."
    blkdiscard "$EMMC_DEV" 2>/dev/null && echo "  blkdiscard 完成" || echo "  blkdiscard 失败"
    sleep 2
  else
    echo "  设备不支持 discard，跳过 TRIM"
    return
  fi

  fio --filename="$EMMC_DEV" \
      --direct=1 \
      --rw=randwrite \
      --bs=$BS \
      --size=$SIZE \
      --iodepth=1 \
      --numjobs=1 \
      --ioengine=libaio \
      --runtime=30 \
      --time_based \
      --name=trim_after \
      --output="${RESULT_DIR}/trim_after.json" \
      --output-format=json 2>/dev/null

  RESULTS+=("$(parse_fio_result "${RESULT_DIR}/trim_after.json" "TRIM后-恢复")")
}

# --- 阶段4: 在线 TRIM (fstrim) ---
fstrim_test() {
  echo ""
  echo "--- 阶段4: 文件系统 fstrim ---"
  if mountpoint -q "$MOUNT_POINT"; then
    echo "  执行 fstrim -v ${MOUNT_POINT} ..."
    fstrim -v "$MOUNT_POINT" 2>&1 || echo "  fstrim 失败"
  else
    echo "  [跳过] $MOUNT_POINT 未挂载"
  fi
}

baseline_perf
dirty_perf
trim_perf
fstrim_test

echo ""
echo "====== TRIM 测试结果 ======"
for r in "${RESULTS[@]}"; do
  echo "  $r"
done

# 性能恢复率分析
if [ -f "${RESULT_DIR}/trim_baseline.json" ] && [ -f "${RESULT_DIR}/trim_after.json" ]; then
  python3 -c "
import json
b = json.load(open('${RESULT_DIR}/trim_baseline.json'))
a = json.load(open('${RESULT_DIR}/trim_after.json'))
base_iops = b.get('jobs',[{}])[0].get('write',{}).get('iops',0)
after_iops = a.get('jobs',[{}])[0].get('write',{}).get('iops',0)
if base_iops > 0:
    recovery = after_iops / base_iops * 100
    print(f'  性能恢复率: {recovery:.1f}%')
    if recovery > 90:
        print('  [PASS] TRIM 功能正常')
    elif recovery > 50:
        print('  [WARN] TRIM 部分有效，恢复率偏低')
    else:
        print('  [FAIL] TRIM 效果不佳')
"

fi

append_summary "TRIM测试" "${RESULTS[@]}"
