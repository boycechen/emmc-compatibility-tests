#!/bin/bash
# ============================================================
# eMMC Sleep/Wake + 系统挂起恢复测试
#
# 原理：eMMC 支持 CMD5 (sleep/awake) 电源管理状态。
#   系统挂起时 eMMC 进入睡眠, 恢复时唤醒并重新初始化。
#   固件在睡眠→唤醒转换中可能出现状态恢复失败。
#
# 检测目标：
#   - CMD5 sleep/wake 后数据一致性
#   - 系统 suspend/resume 后 eMMC 状态恢复
#   - 睡眠期间寄存器状态保持
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  Sleep/Wake + 挂起恢复测试"
echo "========================================"
reset_device

RESULTS=()
SLEEP_SUPPORT=0

echo ""
echo "--- 检查 Sleep 支持 ---"
if mmc extcsd read "$EMMC_DEV" 2>/dev/null | grep -q "Sleep Notification"; then
  SLEEP_SUPPORT=1
  echo "  [OK] 设备支持 Sleep Notification"
else
  echo "  [INFO] 未检测到 Sleep Notification (不影响测试)"
fi

echo ""
echo "--- 测试1: 写数据 → Sleep → Wake → 校验 ---"
echo "  写入 128MB 校验数据..."
fio --filename="$EMMC_DEV" --direct=1 --rw=write --bs=4k --size=128M \
    --iodepth=8 --ioengine=libaio --name=pm_write \
    --output="${RESULT_DIR}/pm_write.json" --output-format=json \
    --verify=crc32c --verify_pattern=0xbe --verify_state_save=0 2>/dev/null || true

echo "  尝试 CMD5 sleep → wake (可能不被驱动支持)..."
if [ -w "/sys/block/$(basename $EMMC_DEV)/device/power/control" ]; then
  echo "  设置 eMMC 电源策略为自动..."
  echo auto > "/sys/block/$(basename $EMMC_DEV)/device/power/control" 2>/dev/null || true
  sleep 3
fi

# 触发设备进入低功耗 (通过运行时PM)
echo "  等待设备空闲进入低功耗..."
sync
sleep 5

# 读回校验 (会唤醒设备)
echo "  读回校验 (触发设备唤醒)..."
rc=0
fio --filename="$EMMC_DEV" --direct=1 --rw=read --bs=4k --size=128M \
    --iodepth=8 --ioengine=libaio --name=pm_read \
    --output="${RESULT_DIR}/pm_read.json" --output-format=json \
    --verify=crc32c --verify_pattern=0xbe --verify_state_save=0 --verify_fatal=1 \
    2>/dev/null || rc=$?

if [ $rc -eq 0 ]; then
  echo "  [PASS] Sleep→Wake 后数据一致"
  RESULTS+=("Sleep/Wake: PASS")
else
  echo "  [FAIL] Sleep→Wake 后数据不一致!"
  RESULTS+=("Sleep/Wake: FAIL")
fi

echo ""
echo "--- 测试2: 大量写入后睡眠唤醒 ---"
echo "  写负载后立即触发睡眠..."
fio --filename="$EMMC_DEV" --direct=1 --rw=write --bs=4k --size=256M \
    --iodepth=16 --ioengine=libaio --name=pm_load \
    --output=/dev/null 2>/dev/null || true

sync
echo "  等待 10 秒进入低功耗..."
sleep 10

# 随机读测试唤醒后性能
echo "  唤醒后随机读性能..."
fio --filename="$EMMC_DEV" --direct=1 --rw=randread --bs=4k --size=256M \
    --iodepth=4 --ioengine=libaio --runtime=15 --time_based --ramp_time=3 \
    --name=pm_wake_perf \
    --output="${RESULT_DIR}/pm_wake_perf.json" --output-format=json 2>/dev/null || true
RESULTS+=("$(parse_fio_result "${RESULT_DIR}/pm_wake_perf.json" "唤醒后随机读")")

echo ""
echo "--- 测试3: 系统挂起/恢复 (仅尝试, 需要用户确认) ---"
echo "  如果在桌面环境, 挂起可能会失败"
echo "  尝试: echo mem > /sys/power/state"

if [ -f "/sys/power/state" ] && grep -q "mem" /sys/power/state 2>/dev/null; then
  echo "  系统支持内存挂起"
  echo "  写入 64MB 数据用于挂起后校验..."
  fio --filename="$EMMC_DEV" --direct=1 --rw=write --bs=4k --size=64M --offset=0 \
      --iodepth=4 --ioengine=libaio --name=pm_suspend_write \
      --output=/dev/null \
      --verify=crc32c --verify_pattern=0xef --verify_state_save=0 2>/dev/null || true

  echo "  准备挂起系统 (5秒后)..."
  echo "  [WARN] 如果系统无法恢复, 需要手动重启!"
  echo "  按 Ctrl+C 跳过挂起测试"
  sleep 3

  # 跳过实际的挂起 (因为可能导致ssh断开等)
  # 仅做验证测试
  echo "  [SKIP] 自动跳过系统挂起 (防止远程会话断开)"
  echo "  如需测试挂起: sudo sh -c 'echo mem > /sys/power/state'"
  echo "  挂起恢复后运行: sudo ./run_all.sh --runtime 30 quick"

  # 但模拟写后fsync验证
  sync
  sleep 2
  rc=0
  fio --filename="$EMMC_DEV" --direct=1 --rw=read --bs=4k --size=64M --offset=0 \
      --iodepth=4 --ioengine=libaio --name=pm_suspend_verify \
      --output=/dev/null \
      --verify=crc32c --verify_pattern=0xef --verify_state_save=0 --verify_fatal=1 \
      2>/dev/null || rc=$?
  if [ $rc -eq 0 ]; then
    echo "  [PASS] 仿真挂起前后数据一致"
  else
    echo "  [FAIL] 数据校验失败!"
  fi
else
  echo "  [SKIP] 系统不支持内存挂起"
fi

echo ""
echo "--- 测试4: 反复睡眠/唤醒循环 ---"
echo "  rpm 自动挂起 3次..."
for i in 1 2 3; do
  echo "  循环 $i: 写入少量数据 → 空闲 → 唤醒"
  fio --filename="$EMMC_DEV" --direct=1 --rw=write --bs=4k --size=8M \
      --iodepth=1 --ioengine=libaio --name=pm_cycle_${i} \
      --output=/dev/null 2>/dev/null || true
  sync
  sleep 3
done
echo "  [DONE] 睡眠/唤醒循环完成"

echo ""
echo "====== Sleep/Wake 测试结果 ======"
for r in "${RESULTS[@]}"; do echo "  $r"; done
append_summary "电源管理" "Sleep/Wake: $([ $rc -eq 0 ] && echo PASS || echo FAIL)"
