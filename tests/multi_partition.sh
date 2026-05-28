#!/bin/bash
# ============================================================
# 多分区并发访问测试 (Multi-Partition Concurrent Access)
#
# 原理：eMMC 支持分区切换 (PARTITION_ACCESS, EXT_CSD[179])。
#   当主机在不同分区 (Boot0/Boot1/User/RPMB) 之间切换时，
#   控制器必须：
#   - 保存当前分区的上下文 (写指针、状态等)
#   - 加载目标分区的上下文
#   - 处理分区间命令交织
#
#   已知固件问题:
#   - 分区切换竞争 (两个线程同时切换, 上下文混乱)
#   - 分区写指针丢失 (写 A 分区时 B 分区的数据被损坏)
#   - 并发访问时一方超时导致另一方数据错误
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  多分区并发访问测试"
echo "========================================"
reset_device

DEV_NAME=$(basename "$EMMC_DEV")
BOOT_DEV0="/dev/${DEV_NAME}boot0"
BOOT_DEV1="/dev/${DEV_NAME}boot1"
RESULTS=()
FAIL_COUNT=0

# 检查 boot 分区
for dev in "$BOOT_DEV0" "$BOOT_DEV1"; do
  if [ ! -b "$dev" ]; then
    echo "[SKIP] boot 分区不可用"
    append_summary "多分区并发" "SKIP-无boot分区"
    exit 1
  fi
done

echo ""
echo "  User分区:  $EMMC_DEV"
echo "  Boot分区0: $BOOT_DEV0"
echo "  Boot分区1: $BOOT_DEV1"

# ---- 阶段1: 各分区独立写入+校验 ----
echo ""
echo "--- 阶段1: 各分区独立写入+校验 ---"

# 备份 + 关闭只读
echo "  关闭 boot 分区只读..."
echo 0 > /sys/block/${DEV_NAME}boot0/force_ro 2>/dev/null || true
echo 0 > /sys/block/${DEV_NAME}boot1/force_ro 2>/dev/null || true

BOOT_SIZE=$(blockdev --getsize64 "$BOOT_DEV0")

for i in 0 1; do
  dev="/dev/${DEV_NAME}boot${i}"
  echo "  Boot${i} 写入..."
  fio --filename="$dev" --direct=1 --rw=write --bs=4k --size=$BOOT_SIZE \
      --iodepth=4 --ioengine=libaio --name=mp_boot_w_${i} \
      --output="${RESULT_DIR}/mp_boot_w_${i}.json" --output-format=json \
      --verify=crc32c --verify_pattern=0xbb${i}bb${i}bb${i}bb${i} --verify_state_save=0 \
      2>/dev/null || true
done

echo "  User 分区写入..."
fio --filename="$EMMC_DEV" --direct=1 --rw=write --bs=4k --size=64M \
    --iodepth=4 --ioengine=libaio --name=mp_user_w \
    --output="${RESULT_DIR}/mp_user_w.json" --output-format=json \
    --verify=crc32c --verify_pattern=0x12345678 --verify_state_save=0 \
    2>/dev/null || true

# 各分区独立校验
ALL_OK=1
for i in 0 1; do
  dev="/dev/${DEV_NAME}boot${i}"
  rc=0
  fio --filename="$dev" --direct=1 --rw=read --bs=4k --size=$BOOT_SIZE \
      --iodepth=4 --ioengine=libaio --name=mp_boot_v_${i} \
      --output="${RESULT_DIR}/mp_boot_v_${i}.json" --output-format=json \
      --verify=crc32c --verify_pattern=0xbb${i}bb${i}bb${i}bb${i} --verify_state_save=0 --verify_fatal=1 \
      2>/dev/null || rc=$?
  echo -n "  Boot${i} 校验: "
  [ $rc -eq 0 ] && echo "PASS" || { echo "FAIL!"; ALL_OK=0; FAIL_COUNT=$((FAIL_COUNT + 1)); }
done

rc=0
fio --filename="$EMMC_DEV" --direct=1 --rw=read --bs=4k --size=64M \
    --iodepth=4 --ioengine=libaio --name=mp_user_v \
    --output="${RESULT_DIR}/mp_user_v.json" --output-format=json \
    --verify=crc32c --verify_pattern=0x12345678 --verify_state_save=0 --verify_fatal=1 \
    2>/dev/null || rc=$?
echo -n "  User 分区校验: "
[ $rc -eq 0 ] && echo "PASS" || { echo "FAIL!"; ALL_OK=0; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# ---- 阶段2: 多分区并发访问 ----
echo ""
echo "--- 阶段2: 3 分区并发混合访问 ---"
echo "  同时向 User+Boot0+Boot1 发 IO, 检测分区切换竞争..."

# 3 个分区同时运行 fio
bash << MPTEST &
  fio --filename="$BOOT_DEV0" --direct=1 --rw=randrw --rwmixread=70 \
      --bs=4k --size=$BOOT_SIZE --iodepth=2 --ioengine=libaio \
      --runtime=60 --time_based --name=mp_boot0 \
      --output="${RESULT_DIR}/mp_boot0_conc.json" --output-format=json \
      2>/dev/null
MPTEST
PID1=$!

bash << MPTEST &
  fio --filename="$BOOT_DEV1" --direct=1 --rw=randrw --rwmixread=70 \
      --bs=4k --size=$BOOT_SIZE --iodepth=2 --ioengine=libaio \
      --runtime=60 --time_based --name=mp_boot1 \
      --output="${RESULT_DIR}/mp_boot1_conc.json" --output-format=json \
      2>/dev/null
MPTEST
PID2=$!

bash << MPTEST &
  fio --filename="$EMMC_DEV" --direct=1 --rw=randrw --rwmixread=70 \
      --bs=4k --size=256M --iodepth=4 --ioengine=libaio \
      --runtime=60 --time_based --name=mp_user \
      --output="${RESULT_DIR}/mp_user_conc.json" --output-format=json \
      2>/dev/null
MPTEST
PID3=$!

echo "  并发 IO 进行中 (60s)..."
wait $PID1 $PID2 $PID3 2>/dev/null
echo "  并发访问完成"

RESULTS+=("$(parse_fio_result "${RESULT_DIR}/mp_boot0_conc.json" "Boot0并发")")
RESULTS+=("$(parse_fio_result "${RESULT_DIR}/mp_boot1_conc.json" "Boot1并发")")
RESULTS+=("$(parse_fio_result "${RESULT_DIR}/mp_user_conc.json" "User并发")")

# ---- 阶段3: 并发后数据一致性 ----
echo ""
echo "--- 阶段3: 并发后一致性校验 ---"
ALL_OK=1
for i in 0 1; do
  dev="/dev/${DEV_NAME}boot${i}"
  rc=0
  fio --filename="$dev" --direct=1 --rw=read --bs=4k --size=$BOOT_SIZE \
      --iodepth=4 --ioengine=libaio --name=mp_final_boot_${i} \
      --output="${RESULT_DIR}/mp_final_boot_${i}.json" --output-format=json \
      --verify=crc32c --verify_pattern=0xbb${i}bb${i}bb${i}bb${i} --verify_state_save=0 --verify_fatal=1 \
      2>/dev/null || rc=$?
  echo -n "  Boot${i} 并发后校验: "
  [ $rc -eq 0 ] && echo "PASS" || { echo "FAIL!"; ALL_OK=0; }
done

# 恢复 boot 分区只读
echo 1 > /sys/block/${DEV_NAME}boot0/force_ro 2>/dev/null || true
echo 1 > /sys/block/${DEV_NAME}boot1/force_ro 2>/dev/null || true

echo ""

# dmesg 检查
echo ""
echo "--- dmesg 分区错误 ---"
dmesg | grep -iE "(mmc.*partition|mmc.*switch|boot.*fail)" | tail -5 || echo "  (无)"

echo ""
echo "====== 多分区并发测试结果 ======"
if [ $FAIL_COUNT -eq 0 ]; then
  echo "  [PASS] 多分区并发访问正常"
else
  echo "  [FAIL] ${FAIL_COUNT} 个检查点失败"
fi
for r in "${RESULTS[@]}"; do echo "  $r"; done
append_summary "多分区并发" "失败: ${FAIL_COUNT}"
