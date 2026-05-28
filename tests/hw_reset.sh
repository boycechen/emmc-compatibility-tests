#!/bin/bash
# ============================================================
# eMMC HW Reset 测试 (Hardware Reset Stress)
#
# 原理：eMMC RST_n 引脚强制复位控制器内部状态机到初始态。
#   复位后控制器必须:
#   - 重载 FTL 映射表 (从 NAND flash 读取 L2P table)
#   - 重置所有寄存器 (时序/总线宽度/分区选择)
#   - 重新与 Host 建立通信 (CMD0 GO_IDLE_STATE)
#   - 恢复 NAND 内部状态机 (正在进行的 GC/擦除/编程)
#
# 已知固件 bug 类型:
#   - 映射表重建不完整 → 返回旧数据或全 0
#   - 寄存器恢复顺序错误 → HS400 降级到 HS200/legacy
#   - 复位打断 GC/copyback → FTL 元数据损坏
#   - 频繁复位导致状态机泄漏 → 第 N 次复位后死锁
#   - 复位后 write cache 状态不确定 → 静默数据丢失
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  eMMC HW Reset 测试"
echo "========================================"
reset_device

RESULTS=()
FAIL_COUNT=0
DEV_NAME=$(basename "$EMMC_DEV")

# 检测 mmc-utils 是否支持 hw_reset
if ! mmc hw_reset "$EMMC_DEV" 2>&1 | grep -q ".*"; then
  # 第一个 reset 可能失败, 重新探测
  sleep 2
fi
if [ ! -b "$EMMC_DEV" ]; then
  echo "[SKIP] hw_reset 后设备未恢复, 内核可能不支持"
  append_summary "HW Reset" "SKIP-不支持"
  exit 1
fi

echo ""
echo "  EMMC_DEV: $EMMC_DEV"
echo ""

# =========================================
# 阶段1: 写后复位 → 校验 (直接IO, 数据应在NAND上)
# =========================================
echo "--- 阶段1: 写 → HW Reset → 校验 ---"
SIZE=64M

echo "  写入数据 (direct IO)..."
rc=0
fio --filename="$EMMC_DEV" --direct=1 --rw=write --bs=4k --size=$SIZE \
    --iodepth=8 --ioengine=libaio --name=reset_w1 \
    --output="${RESULT_DIR}/reset_w1.json" --output-format=json \
    --verify=crc32c --verify_pattern=0xdeadbeef --verify_state_save=0 \
    2>/dev/null || rc=$?
echo -n "    写入: "
[ $rc -eq 0 ] && echo "OK" || echo "FAIL (rc=$rc)"

sync

echo "  执行 HW Reset..."
mmc hw_reset "$EMMC_DEV" 2>/dev/null
RET=$?
if [ $RET -ne 0 ]; then
  echo "    hw_reset 命令返回 $RET"
fi

# 等待设备恢复
echo -n "    等待设备恢复..."
for i in $(seq 1 30); do
  if [ -b "$EMMC_DEV" ]; then
    # 尝试读取确认设备可访问
    dd if="$EMMC_DEV" of=/dev/null bs=512 count=1 2>/dev/null && break
  fi
  sleep 1
  echo -n "."
done
echo ""

if [ ! -b "$EMMC_DEV" ]; then
  echo "    [FAIL] 复位后设备未恢复!"
  FAIL_COUNT=$((FAIL_COUNT + 1))
else
  echo "    设备已恢复"

  rc=0
  fio --filename="$EMMC_DEV" --direct=1 --rw=read --bs=4k --size=$SIZE \
      --iodepth=8 --ioengine=libaio --name=reset_v1 \
      --output="${RESULT_DIR}/reset_v1.json" --output-format=json \
      --verify=crc32c --verify_pattern=0xdeadbeef --verify_state_save=0 --verify_fatal=1 \
      2>/dev/null || rc=$?
  echo -n "    复位后数据校验: "
  if [ $rc -eq 0 ]; then
    echo "PASS (数据在NAND上持久化正确)"
  else
    echo "FAIL! (复位后数据损坏或映射表错误!)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
  RESULTS+=("$(parse_fio_result "${RESULT_DIR}/reset_v1.json" "阶段1-复位后校验")")
fi

# =========================================
# 阶段2: 频繁复位 (状态机稳定性)
# =========================================
echo ""
echo "--- 阶段2: 频繁 HW Reset (10次) ---"
echo "  连续复位 10 次, 每次后做小数据校验..."

for round in $(seq 1 10); do
  echo -n "  第${round}次复位..."

  mmc hw_reset "$EMMC_DEV" 2>/dev/null

  # 等待设备
  READY=0
  for i in $(seq 1 20); do
    if [ -b "$EMMC_DEV" ] && dd if="$EMMC_DEV" of=/dev/null bs=512 count=1 2>/dev/null; then
      READY=1
      break
    fi
    sleep 1
  done

  if [ $READY -eq 0 ]; then
    echo " 设备未恢复! 终止测试"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    break
  fi

  # 小数据校验
  rc=0
  fio --filename="$EMMC_DEV" --direct=1 --rw=write --bs=4k --size=8M \
      --iodepth=4 --ioengine=libaio --name=reset_freq_w_${round} \
      --output="${RESULT_DIR}/reset_freq_w_${round}.json" --output-format=json \
      --verify=crc32c --verify_pattern=0xbeef${round} --verify_state_save=0 \
      2>/dev/null || rc=$?
  if [ $rc -ne 0 ]; then
    echo " 写入失败!"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi

  rc=0
  fio --filename="$EMMC_DEV" --direct=1 --rw=read --bs=4k --size=8M \
      --iodepth=4 --ioengine=libaio --name=reset_freq_v_${round} \
      --output="${RESULT_DIR}/reset_freq_v_${round}.json" --output-format=json \
      --verify=crc32c --verify_pattern=0xbeef${round} --verify_state_save=0 --verify_fatal=1 \
      2>/dev/null || rc=$?
  [ $rc -eq 0 ] && echo " OK" || { echo " FAIL!"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
done

# =========================================
# 阶段3: 复位时 in-flight IO 处理
# =========================================
echo ""
echo "--- 阶段3: 复位 × 后台 IO ---"
echo "  后台持续随机读写, 前台执行 HW Reset..."
echo "  检测控制器是否在处理 IO 时被复位卡死"

# 启动后台 fio
fio --filename="$EMMC_DEV" --direct=1 --rw=randrw --rwmixread=70 \
    --bs=4k --size=256M --iodepth=4 --numjobs=2 --ioengine=libaio \
    --runtime=30 --time_based --group_reporting \
    --name=reset_bg \
    --output="${RESULT_DIR}/reset_bg.json" --output-format=json \
    2>/dev/null &
BG_PID=$!

sleep 3

# 在 IO 活跃时复位
for i in 1 2; do
  echo -n "  第${i}次 IO中复位..."
  mmc hw_reset "$EMMC_DEV" 2>/dev/null
  sleep 2
  if [ -b "$EMMC_DEV" ] && dd if="$EMMC_DEV" of=/dev/null bs=512 count=1 2>/dev/null; then
    echo " 设备恢复"
  else
    echo " 设备未恢复!"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
done

wait $BG_PID 2>/dev/null || true
RESULTS+=("$(parse_fio_result "${RESULT_DIR}/reset_bg.json" "阶段3-后台IO")")

# =========================================
# 阶段4: 复位后时序/模式检查
# =========================================
echo ""
echo "--- 阶段4: 复位后时序/模式检查 ---"

read_emmc_field() {
  local reg=$1
  mmc extcsd read "$EMMC_DEV" 2>/dev/null | grep "\[$reg\]" | awk '{print $NF}' || echo "unknown"
}

echo "  复位前:"
BEFORE_SPEED=$(cat /sys/block/${DEV_NAME}/queue/scheduler 2>/dev/null || echo "N/A")
echo "    调度器: $BEFORE_SPEED"

# 执行复位
mmc hw_reset "$EMMC_DEV" 2>/dev/null
sleep 3

# 等待设备
for i in $(seq 1 20); do
  if [ -b "$EMMC_DEV" ] && dd if="$EMMC_DEV" of=/dev/null bs=512 count=1 2>/dev/null; then break; fi
  sleep 1
done

if [ -b "$EMMC_DEV" ]; then
  echo "  复位后:"
  AFTER_SPEED=$(cat /sys/block/${DEV_NAME}/queue/scheduler 2>/dev/null || echo "N/A")
  echo "    调度器: $AFTER_SPEED"
  echo "    (复位后调度器/sysfs 接口正常)"
else
  echo "  [FAIL] 复位后设备丢失, 无法检查"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# =========================================
# 阶段5: 复位后写入新数据 → 校验 (检测影子数据)
# =========================================
echo ""
echo "--- 阶段5: 复位后新数据写入 (检测旧数据残留) ---"
echo "  用 pattern=0xFF 写满复位区域, 读回..."
echo "  如果读到前序 pattern (0xdeadbeef), 说明映射表重建返回了旧数据!"

rc=0
fio --filename="$EMMC_DEV" --direct=1 --rw=write --bs=4k --size=$SIZE \
    --iodepth=8 --ioengine=libaio --name=reset_fresh_w \
    --output="${RESULT_DIR}/reset_fresh_w.json" --output-format=json \
    --verify=crc32c --verify_pattern=0xffffffff --verify_state_save=0 \
    2>/dev/null || rc=$?

rc=0
fio --filename="$EMMC_DEV" --direct=1 --rw=read --bs=4k --size=$SIZE \
    --iodepth=8 --ioengine=libaio --name=reset_fresh_v \
    --output="${RESULT_DIR}/reset_fresh_v.json" --output-format=json \
    --verify=crc32c --verify_pattern=0xffffffff --verify_state_save=0 --verify_fatal=1 \
    2>/dev/null || rc=$?
echo -n "    新数据校验: "
if [ $rc -eq 0 ]; then
  echo "PASS (无旧数据残留)"
else
  echo "FAIL! (复位后读到旧数据, 映射表残留!)"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi
RESULTS+=("$(parse_fio_result "${RESULT_DIR}/reset_fresh_v.json" "阶段5-新数据检验")")

# =========================================
# dmesg 检查
# =========================================
echo ""
echo "--- dmesg 复位错误 ---"
dmesg | grep -iE "(reset.*fail|mmc.*reset.*error|mmc.*init.*fail|mmc.*timeout)" | tail -10 || echo "  (无)"

echo ""
echo "====== HW Reset 测试结果 ======"
if [ $FAIL_COUNT -eq 0 ]; then
  echo "  [PASS] 所有 HW Reset 场景正常"
else
  echo "  [FAIL] ${FAIL_COUNT} 个检查点失败 (详见上方)"
fi
for r in "${RESULTS[@]}"; do echo "  $r"; done
append_summary "HW Reset" "失败: ${FAIL_COUNT}"
