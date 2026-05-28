#!/bin/bash
# ============================================================
# Boot 分区可靠性测试 (Boot Partition Integrity)
#
# 原理：eMMC 包含 2 个独立 Boot 分区（通常各 4MB），
#   使用 SLC 模式编程，可靠性高于 User 分区的 TLC/QLC。
#   Boot 分区有独立的：
#   - 编程模式 (SLC, 1-bit per cell)
#   - 增强型 ECC
#   - 分区访问控制 (RST_n 信号 + EXT_CSD 配置)
#   - 写保护 (永久/临时)
#
# 常见问题:
#   - SLC 与 TLC 共享字线时的干扰
#   - 分区切换上下文丢失
#   - 写保护状态错误
#   - Boot 分区数据静默损坏
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "============================================"
echo "  Boot 分区可靠性测试"
echo "============================================"

DEV_NAME=$(basename "$EMMC_DEV")
BOOT_DEV0="/dev/${DEV_NAME}boot0"
BOOT_DEV1="/dev/${DEV_NAME}boot1"
RESULTS=()
FAIL_COUNT=0

# 检查 boot 分区是否存在
for dev in "$BOOT_DEV0" "$BOOT_DEV1"; do
  if [ ! -b "$dev" ]; then
    echo "[SKIP] 未找到 boot 分区设备: $dev"
    append_summary "Boot分区($dev)" "SKIP-设备不存在"
    exit 1
  fi
done

BOOT_SIZE=$(blockdev --getsize64 "$BOOT_DEV0")
echo ""
echo "  Boot分区0: $BOOT_DEV0 ($(numfmt --to=iec $BOOT_SIZE))"
echo "  Boot分区1: $BOOT_DEV1 ($(numfmt --to=iec $BOOT_SIZE))"

# ---- 阶段0: 记录原始内容 (用于恢复) ----
echo ""
echo "--- 阶段0: 备份 boot 分区原始内容 ---"
echo "  [WARN] 测试会写入 boot 分区!"
echo "  按 Ctrl+C 在 5 秒内取消..."
sleep 5

mkdir -p "${LOG_DIR}/boot_backup"
dd if="$BOOT_DEV0" of="${LOG_DIR}/boot_backup/boot0.bin" bs=1M status=none 2>/dev/null
dd if="$BOOT_DEV1" of="${LOG_DIR}/boot_backup/boot1.bin" bs=1M status=none 2>/dev/null
echo "  已备份 boot 分区原始内容"

# 临时关闭只读保护
echo "  临时关闭只读保护..."
echo 0 > /sys/block/${DEV_NAME}boot0/force_ro 2>/dev/null || echo "  [WARN] 无法关闭 boot0 只读保护"
echo 0 > /sys/block/${DEV_NAME}boot1/force_ro 2>/dev/null || echo "  [WARN] 无法关闭 boot1 只读保护"

# ---- 阶段1: boot0 SLC 模式写入+校验 ----
echo ""
echo "--- 阶段1: Boot0 SLC 写入+校验 ---"
for i in 0 1; do
  dev="/dev/${DEV_NAME}boot${i}"
  echo "  [Boot分区${i}] 写入+校验..."

  rc=0
  fio --filename="$dev" --direct=1 --rw=write --bs=4k --size=${BOOT_SIZE} \
      --iodepth=8 --ioengine=libaio --name=boot_w_${i} \
      --output="${RESULT_DIR}/boot_w_${i}.json" --output-format=json \
      --verify=crc32c --verify_pattern=0xaabbccdd --verify_state_save=0 \
      2>/dev/null || rc=$?
  echo -n "    写入: "
  [ $rc -eq 0 ] && echo "OK" || echo "FAIL"

  rc=0
  fio --filename="$dev" --direct=1 --rw=read --bs=4k --size=${BOOT_SIZE} \
      --iodepth=8 --ioengine=libaio --name=boot_v_${i} \
      --output="${RESULT_DIR}/boot_v_${i}.json" --output-format=json \
      --verify=crc32c --verify_pattern=0xaabbccdd --verify_state_save=0 --verify_fatal=1 \
      2>/dev/null || rc=$?
  echo -n "    校验: "
  if [ $rc -eq 0 ]; then
    echo "PASS"
  else
    echo "FAIL! (SLC 模式数据异常!)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
  RESULTS+=("$(parse_fio_result "${RESULT_DIR}/boot_v_${i}.json" "Boot${i}-SLC")")
done

# ---- 阶段2: 数据pattern在SLC模式下的完整性 ----
echo ""
echo "--- 阶段2: Boot SLC Pattern 遍历 ---"
for i in 0 1; do
  dev="/dev/${DEV_NAME}boot${i}"
  for pat in "0xffffffff" "0x00000000" "0xaaaaaaaa"; do
    echo -n "  boot${i} pat=${pat} ... "
    fio --filename="$dev" --direct=1 --rw=write --bs=4k --size=${BOOT_SIZE} \
        --iodepth=4 --ioengine=libaio --name=boot_pat_w \
        --output=/dev/null \
        --verify=crc32c --verify_pattern=$pat --verify_state_save=0 \
        2>/dev/null || true
    rc=0
    fio --filename="$dev" --direct=1 --rw=read --bs=4k --size=${BOOT_SIZE} \
        --iodepth=4 --ioengine=libaio --name=boot_pat_v \
        --output=/dev/null \
        --verify=crc32c --verify_pattern=$pat --verify_state_save=0 --verify_fatal=1 \
        2>/dev/null || rc=$?
    [ $rc -eq 0 ] && echo "PASS" || { echo "FAIL"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
  done
done

# ---- 阶段3: Boot 分区多轮写磨耗 ----
echo ""
echo "--- 阶段3: Boot 分区磨耗 (20次全写+校验) ---"
for i in 0 1; do
  dev="/dev/${DEV_NAME}boot${i}"
  echo "  Boot${i} 反复写校验... (模拟SLC磨耗)"
  for round in $(seq 1 20); do
    echo -n "    第${round}轮 ... "
    fio --filename="$dev" --direct=1 --rw=write --bs=4k --size=${BOOT_SIZE} \
        --iodepth=4 --ioengine=libaio --name=boot_wear_w \
        --output=/dev/null --verify=crc32c --verify_pattern=0xdead$((round * 0x1111 & 0xFFFF)) \
        --verify_state_save=0 2>/dev/null || true
    rc=0
    fio --filename="$dev" --direct=1 --rw=read --bs=4k --size=${BOOT_SIZE} \
        --iodepth=4 --ioengine=libaio --name=boot_wear_v \
        --output="${RESULT_DIR}/boot_wear_${i}_r${round}.json" --output-format=json \
        --verify=crc32c --verify_pattern=0xdead$((round * 0x1111 & 0xFFFF)) \
        --verify_state_save=0 --verify_fatal=1 2>/dev/null || rc=$?
    [ $rc -eq 0 ] && echo "OK" || { echo "FAIL!"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
  done
done

# ---- 恢复原始内容 ----
echo ""
echo "--- 恢复 Boot 分区原始内容 ---"
dd if="${LOG_DIR}/boot_backup/boot0.bin" of="$BOOT_DEV0" bs=1M status=none 2>/dev/null
dd if="${LOG_DIR}/boot_backup/boot1.bin" of="$BOOT_DEV1" bs=1M status=none 2>/dev/null
echo "  原始内容已恢复"

echo 1 > /sys/block/${DEV_NAME}boot0/force_ro 2>/dev/null || true
echo 1 > /sys/block/${DEV_NAME}boot1/force_ro 2>/dev/null || true

echo ""
echo "====== Boot 分区测试结果 ======"
if [ $FAIL_COUNT -eq 0 ]; then
  echo "  [PASS] Boot 分区 SLC 模式工作正常"
else
  echo "  [FAIL] ${FAIL_COUNT} 个检查点失败!"
fi
for r in "${RESULTS[@]}"; do echo "  $r"; done
append_summary "Boot分区" "失败: ${FAIL_COUNT}"
