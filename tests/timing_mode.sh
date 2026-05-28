#!/bin/bash
# ============================================================
# eMMC 时序模式测试 (Timing Mode)
#
# 原理：eMMC 支持 HS400/HS200/DDR52/HS SDR 等时序。
#   高速模式(HS400)信号完整性要求高，部分 eMMC 在 HS400
#   下偶发错误但在降级模式下正常。检测当前模式下的稳定性。
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  时序模式测试 (Timing Mode)"
echo "========================================"
reset_device

RESULTS=()
DEV_NAME=$(basename "$EMMC_DEV")

# --- 读取 eMMC 时序/速度信息 ---
echo ""
echo "--- 当前时序参数 ---"
for path in /sys/kernel/debug/mmc*/ios; do
  [ -f "$path" ] && cat "$path" 2>/dev/null | head -10
done

# 检查 HS400 是否启用
HS400_ENABLED=0
for path in /sys/kernel/debug/mmc*/mmc*/hs400_tuning; do
  [ -f "$path" ] && HS400_ENABLED=$(cat "$path" 2>/dev/null || echo 0)
done
echo "  HS400 tuning: $HS400_ENABLED"

# 读取支持的时序
SUPPORTED_TIMING=""
for path in /sys/kernel/debug/mmc*/mmc*/ext_csd; do
  if [ -f "$path" ]; then
    # EXT_CSD[196] device_type 显示支持的时序
    local dev_type=$(grep "EXT_CSD\[196\]" "$path" 2>/dev/null | awk '{print $NF}')
    [ -n "$dev_type" ] && SUPPORTED_TIMING="$dev_type"
  fi
done
echo "  设备类型: $SUPPORTED_TIMING"

echo ""
echo "--- HS400 稳定性测试 ---"
echo "  大负载下数据一致性 (HS400/HS200)"

for mode_label in "当前模式" ""; do
  echo "  测试: $mode_label 64MB 写+校验..."
  fio --filename="$EMMC_DEV" --direct=1 --rw=write --bs=4k --size=64M \
      --iodepth=4 --ioengine=libaio --name=timing_w \
      --output="${RESULT_DIR}/timing_write.json" --output-format=json \
      --verify=crc32c --verify_pattern=0x55 --verify_state_save=0 2>/dev/null || true

  rc=0
  fio --filename="$EMMC_DEV" --direct=1 --rw=read --bs=4k --size=64M \
      --iodepth=4 --ioengine=libaio --name=timing_r \
      --output="${RESULT_DIR}/timing_read.json" --output-format=json \
      --verify=crc32c --verify_pattern=0x55 --verify_state_save=0 --verify_fatal=1 \
      2>/dev/null || rc=$?

  if [ $rc -eq 0 ]; then
    echo "    [PASS] 数据一致"
  else
    echo "    [FAIL] 校验失败! 可能时序不稳定"
  fi
  RESULTS+=("$(parse_fio_result "${RESULT_DIR}/timing_write.json" "时序-${mode_label}")")
done

echo ""
echo "--- HS400 突发压力测试 ---"
echo "  高队列深度+长时运行, 检测 HS400 下偶发错误..."

fio --filename="$EMMC_DEV" --direct=1 --rw=randrw --rwmixread=70 \
    --bs=4k --size=2G --iodepth=32 --numjobs=2 --ioengine=libaio \
    --group_reporting --runtime=120 --time_based --ramp_time=10 \
    --name=timing_stress \
    --output="${RESULT_DIR}/timing_stress.json" --output-format=json \
    --write_lat_log="${LOG_DIR}/timing_lat" 2>/dev/null

RESULTS+=("$(parse_fio_result "${RESULT_DIR}/timing_stress.json" "HS400长时压力")")

# 检查错误计数
echo ""
echo "--- 硬件错误计数 ---"
for path in /sys/block/${DEV_NAME}/device/*_errors; do
  [ -f "$path" ] && echo "  $(basename $path): $(cat $path)"
done

for path in /sys/devices/platform/*/mmc_host/mmc*/mmc*/*_errors; do
  [ -f "$path" ] && echo "  $(basename $path): $(cat $path)"
done 2>/dev/null || true

echo ""
echo "====== 时序模式测试结果 ======"
for r in "${RESULTS[@]}"; do echo "  $r"; done
append_summary "时序模式" "HS400压力测试完成"
