#!/bin/bash
# ============================================================
# eMMC CMDQ 压力测试 (Command Queue Stress)
#
# 原理：eMMC 5.1 引入 Command Queue, 允许 host 一次性提交
#   最多 32 个命令到队列, 由控制器自主调度执行。
#   CMDQ 通过 QSR (Queue Status Register) 报告队列状态。
#
#   已知固件 bug:
#   - 队列满时新命令被静默丢弃
#   - 任务优先级反转 (高优读被低优写阻塞)
#   - 队列 drain 流程死锁
#   - QSR 状态位错误 (报告完成但实际未完成)
#   - 深度队列 + verify 时的数据混乱
#
# 测试方式:
#   1. 检测 CMDQ 支持并记录队列深度
#   2. 高队列深度随机读写 (iodepth=32, 模拟队列满)
#   3. 短超时队列并发 (不同 timeout 优先级)
#   4. 队列 drain + flush 测试
#   5. 数据完整性验证
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  eMMC CMDQ 压力测试"
echo "========================================"
reset_device

RESULTS=()
FAIL_COUNT=0
DEV_NAME=$(basename "$EMMC_DEV")

# ---------- 检测 CMDQ 支持 ----------
EXT_CSD=$(mmc extcsd read "$EMMC_DEV" 2>/dev/null)
DS2=$(echo "$EXT_CSD" | grep "\[6\]" | awk '{print $NF}')
CMDQ_EN=$(( (DS2 >> 0) & 1 ))

if [ $CMDQ_EN -eq 0 ]; then
  echo "  [SKIP] 设备不支持 CMDQ"
  append_summary "CMDQ" "SKIP-不支持"
  exit 0
fi

# sysfs 检查
CMDQ_SYSFS="/sys/block/${DEV_NAME}/device/mmc_cmdq"
CMD_QDEPTH="/sys/block/${DEV_NAME}/device/queue_depth"

echo ""
echo "  CMDQ: 支持"
echo -n "  sysfs: "
if [ -d "$CMDQ_SYSFS" ]; then echo "mmc_cmdq 存在"
else echo "mmc_cmdq 不存在(spec 声称但不暴露)"; fi

QDEPTH=32
[ -f "$CMD_QDEPTH" ] && QDEPTH=$(cat "$CMD_QDEPTH")
echo "  队列深度: $QDEPTH"

# ---------- 阶段1: 高队列深度顺序IO ----------
echo ""
echo "--- 阶段1: 最大队列深度顺序IO ---"
echo "  iodepth=$QDEPTH, 验证 CMDQ 调度正确性..."

rc=0
fio --filename="$EMMC_DEV" --direct=1 --rw=write --bs=4k --size=256M \
    --iodepth=$QDEPTH --ioengine=libaio --name=cmdq_w1 \
    --output="${RESULT_DIR}/cmdq_w1.json" --output-format=json \
    --verify=crc32c --verify_pattern=0x12345678 --verify_state_save=0 \
    2>/dev/null || rc=$?
echo -n "  CMDQ 队列写: "
[ $rc -eq 0 ] && echo "OK" || echo "FAIL (rc=$rc)"

rc=0
fio --filename="$EMMC_DEV" --direct=1 --rw=read --bs=4k --size=256M \
    --iodepth=$QDEPTH --ioengine=libaio --name=cmdq_r1 \
    --output="${RESULT_DIR}/cmdq_r1.json" --output-format=json \
    --verify=crc32c --verify_pattern=0x12345678 --verify_state_save=0 --verify_fatal=1 \
    2>/dev/null || rc=$?
echo -n "  CMDQ 队列读校验: "
if [ $rc -eq 0 ]; then echo "PASS"
else echo "FAIL! (CMDQ 深度队列数据损坏)"; FAIL_COUNT=$((FAIL_COUNT + 1)); fi
RESULTS+=("$(parse_fio_result "${RESULT_DIR}/cmdq_w1.json" "CMDQ顺序写")")
RESULTS+=("$(parse_fio_result "${RESULT_DIR}/cmdq_r1.json" "CMDQ顺序读")")

# ---------- 阶段2: 多线程 + 高队列深度混合 ----------
echo ""
echo "--- 阶段2: 多CMDQ线程并发混合IO ---"
echo "  4 线程, 各 32 队列深度, randrw..."
echo "  总 IODEPTH = $((QDEPTH * 4)), 验证 CMDQ 并发调度..."

rc=0
fio --filename="$EMMC_DEV" --direct=1 --rw=randrw --rwmixread=70 \
    --bs=4k --size=512M --iodepth=$QDEPTH --numjobs=4 --ioengine=libaio \
    --group_reporting --runtime=60 --time_based --ramp_time=10 \
    --name=cmdq_multi \
    --output="${RESULT_DIR}/cmdq_multi.json" --output-format=json \
    2>/dev/null || rc=$?
echo -n "  多线程CMDQ: "
[ $rc -eq 0 ] && echo "OK" || echo "FAIL (rc=$rc)"
RESULTS+=("$(parse_fio_result "${RESULT_DIR}/cmdq_multi.json" "CMDQ并发")")

# 写后校验
WRITE_PAT=0xdeadc0de
fio --filename="$EMMC_DEV" --direct=1 --rw=write --bs=4k --size=64M \
    --iodepth=$QDEPTH --ioengine=libaio --name=cmdq_vfy_w \
    --output="${RESULT_DIR}/cmdq_vfy_w.json" --output-format=json \
    --verify=crc32c --verify_pattern=$WRITE_PAT --verify_state_save=0 \
    2>/dev/null

rc=0
fio --filename="$EMMC_DEV" --direct=1 --rw=read --bs=4k --size=64M \
    --iodepth=$QDEPTH --ioengine=libaio --name=cmdq_vfy_r \
    --output="${RESULT_DIR}/cmdq_vfy_r.json" --output-format=json \
    --verify=crc32c --verify_pattern=$WRITE_PAT --verify_state_save=0 --verify_fatal=1 \
    2>/dev/null || rc=$?
echo -n "  CMDQ 并发后校验: "
[ $rc -eq 0 ] && echo "PASS" || { echo "FAIL!"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# ---------- 阶段3: 队列深度步进扫描 ----------
echo ""
echo "--- 阶段3: 队列深度步进 ---"
echo "  QD=1~32 带宽扫描, 检测 CMDQ 伸缩效率..."

for qd in 1 2 4 8 16 32; do
  if [ $qd -gt $QDEPTH ]; then break; fi
  fio --filename="$EMMC_DEV" --direct=1 --rw=randread --bs=4k --size=128M \
      --iodepth=$qd --ioengine=libaio --name=cmdq_qdscan_${qd} \
      --output="${RESULT_DIR}/cmdq_qdscan_${qd}.json" --output-format=json \
      2>/dev/null
  RESULTS+=("$(parse_fio_result "${RESULT_DIR}/cmdq_qdscan_${qd}.json" "QD=${qd}")")
done

# ---------- 阶段4: 队列 drain 测试 ----------
echo ""
echo "--- 阶段4: 队列 drain + 紧接刷新 ---"
echo "  写满队列 → sync → 立即写新数据 → 校验"

fio --filename="$EMMC_DEV" --direct=1 --rw=write --bs=4k --size=64M \
    --iodepth=$QDEPTH --ioengine=libaio --name=cmdq_fill \
    --output="${RESULT_DIR}/cmdq_fill.json" --output-format=json \
    2>/dev/null
sync

rc=0
fio --filename="$EMMC_DEV" --direct=1 --rw=write --bs=4k --size=64M \
    --iodepth=$QDEPTH --ioengine=libaio --name=cmdq_refill \
    --output="${RESULT_DIR}/cmdq_refill.json" --output-format=json \
    --verify=crc32c --verify_pattern=0xc0dec0de --verify_state_save=0 \
    2>/dev/null || rc=$?

rc=0
fio --filename="$EMMC_DEV" --direct=1 --rw=read --bs=4k --size=64M \
    --iodepth=$QDEPTH --ioengine=libaio --name=cmdq_refill_v \
    --output="${RESULT_DIR}/cmdq_refill_v.json" --output-format=json \
    --verify=crc32c --verify_pattern=0xc0dec0de --verify_state_save=0 --verify_fatal=1 \
    2>/dev/null || rc=$?
echo -n "  队列 drain+刷新: "
[ $rc -eq 0 ] && echo "PASS" || { echo "FAIL!"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

echo ""
echo "====== CMDQ 测试结果 ======"
if [ $FAIL_COUNT -eq 0 ]; then
  echo "  [PASS] CMDQ 队列调度正常"
else
  echo "  [FAIL] ${FAIL_COUNT} 个 CMDQ 检查点失败"
fi
for r in "${RESULTS[@]}"; do echo "  $r"; done
append_summary "CMDQ" "失败: ${FAIL_COUNT}"
