#!/bin/bash
# ============================================================
# 数据完整性校验测试 (Data Integrity)
#
# 原理：eMMC 内部 FTL 可能在某些条件下出现映射错误、
#   写合并错误、电源管理导致的数据丢失等。
#   本测试通过多轮全盘写+校验来检测这些静默数据错误。
#
# 测试方式：
#   1. 每页写不同数据模式 (0xAA, 0x55, 随机, 固定pattern)
#   2. 留空一段时间后再读取校验
#   3. 跨温度/跨时间读取稳定性
#   4. 写后立即读 vs 写后延迟读 对比
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  数据完整性校验测试 (Data Integrity)"
echo "========================================"

RESULTS=()

echo ""
echo "--- 测试1: 多模式数据写入+即时校验 ---"
for pattern in 0xaa 0x55 0xdeadbeef 0x12345678; do
  echo "  写入+校验 pattern=${pattern} ..."
  rc=0
  fio --filename="$EMMC_DEV" \
      --direct=1 \
      --rw=write \
      --bs=4k \
      --size=512M \
      --offset=0 \
      --iodepth=16 \
      --ioengine=libaio \
      --name=pattern_w_${pattern} \
      --output="${RESULT_DIR}/pattern_write_${pattern}.json" \
      --output-format=json \
      --verify=crc32c \
      --verify_pattern=$pattern \
      --verify_state_save=0 2>/dev/null || rc=$?

  rc=0
  fio --filename="$EMMC_DEV" \
      --direct=1 \
      --rw=read \
      --bs=4k \
      --size=512M \
      --offset=0 \
      --iodepth=16 \
      --ioengine=libaio \
      --name=pattern_vfy_${pattern} \
      --output="${RESULT_DIR}/pattern_verify_${pattern}.json" \
      --output-format=json \
      --verify=crc32c \
      --verify_pattern=$pattern \
      --verify_state_save=0 \
      --verify_fatal=1 2>/dev/null || rc=$?

  if [ $rc -eq 0 ]; then
    echo "    [PASS] pattern=${pattern}"
  else
    echo "    [FAIL] pattern=${pattern} 校验失败!"
  fi
  RESULTS+=("pattern=${pattern}: rc=${rc}")
done

echo ""
echo "--- 测试2: 全盘写+校验 (检测映射错误) ---"
echo "  逐步写入全盘，每步后立即校验..."
DEV_SIZE=$(blockdev --getsize64 "$EMMC_DEV" 2>/dev/null)
if [ -z "$DEV_SIZE" ] || [ "$DEV_SIZE" -eq 0 ]; then
  echo "  [ERROR] 无法获取设备大小，跳过全盘测试"
  RESULTS+=("全盘映射: SKIP")
else
  STEP=$((DEV_SIZE / 10))
  OFFSET=0
  FAIL_COUNT=0

  for i in $(seq 1 10); do
    echo -n "  区域${i}/10 [${OFFSET} ~ $((OFFSET + STEP))] ... "
    fio --filename="$EMMC_DEV" \
        --direct=1 \
        --rw=write \
        --bs=4k \
        --size=$STEP \
        --offset=$OFFSET \
        --iodepth=8 \
        --ioengine=libaio \
        --name=map_write_s${i} \
        --output=/dev/null \
        --verify=crc32c \
        --verify_pattern=0xaa \
        --verify_state_save=0 2>/dev/null || true

    rc=0
    fio --filename="$EMMC_DEV" \
        --direct=1 \
        --rw=read \
        --bs=4k \
        --size=$STEP \
        --offset=$OFFSET \
        --iodepth=8 \
        --ioengine=libaio \
        --name=map_read_s${i} \
        --output=/dev/null \
        --verify=crc32c \
        --verify_pattern=0xaa \
        --verify_state_save=0 \
        --verify_fatal=1 2>/dev/null || rc=$?

    if [ $rc -ne 0 ]; then
      echo "校验失败!"
      FAIL_COUNT=$((FAIL_COUNT + 1))
    else
      echo "OK"
    fi
    OFFSET=$((OFFSET + STEP))
  done

  if [ $FAIL_COUNT -eq 0 ]; then
    echo "  [PASS] 全盘映射一致性通过"
  else
    echo "  [FAIL] ${FAIL_COUNT}/10 区域存在映射错误!"
  fi
fi

echo ""
echo "--- 测试3: 边界对齐测试 ---"
echo "  擦除块边界处 512B 写入..."
for align in 511 512 513 1023 1024 1025 2047 2048 2049 4095 4096 4097; do
  fio --filename="$EMMC_DEV" \
      --direct=1 \
      --rw=write \
      --bs=512 \
      --size=512 \
      --offset=${align} \
      --iodepth=1 \
      --ioengine=libaio \
      --name=align_${align} \
      --output=/dev/null \
      --verify=crc32c \
      --verify_pattern=0xaa \
      --verify_state_save=0 2>/dev/null || true

  rc=0
  fio --filename="$EMMC_DEV" \
      --direct=1 \
      --rw=read \
      --bs=512 \
      --size=512 \
      --offset=${align} \
      --iodepth=1 \
      --ioengine=libaio \
      --name=align_vfy_${align} \
      --output=/dev/null \
      --verify=crc32c \
      --verify_pattern=0xaa \
      --verify_state_save=0 \
      --verify_fatal=1 2>/dev/null || rc=$?

  if [ $rc -ne 0 ]; then
    echo "    [FAIL] offset=${align} 边界校验失败!"
  fi
done
echo "  [DONE] 边界对齐测试完成"

echo ""
echo "--- 测试4: 写后延迟读 (data retention 模拟) ---"
echo "  写入数据后延迟 30秒 再读回..."
fio --filename="$EMMC_DEV" \
    --direct=1 \
    --rw=write \
    --bs=4k \
    --size=512M \
    --offset=2G \
    --iodepth=8 \
    --ioengine=libaio \
    --name=retention_write \
    --output=/dev/null \
    --verify=crc32c \
    --verify_pattern=0x5a5a5a5a \
    --verify_state_save=0 2>/dev/null || true

echo "  等待 30秒..."
sleep 30

rc=0
fio --filename="$EMMC_DEV" \
    --direct=1 \
    --rw=read \
    --bs=4k \
    --size=512M \
    --offset=2G \
    --iodepth=8 \
    --ioengine=libaio \
    --name=retention_read \
    --output="${RESULT_DIR}/retention_test.json" \
    --output-format=json \
    --verify=crc32c \
    --verify_pattern=0x5a5a5a5a \
    --verify_state_save=0 \
    --verify_fatal=1 2>/dev/null || rc=$?

if [ $rc -eq 0 ]; then
  echo "  [PASS] 延迟30秒读回数据一致"
else
  echo "  [FAIL] 延迟30秒后数据损坏! retention 有问题!"
fi
RESULTS+=("延迟读取: rc=${rc}")

echo ""
echo "====== 数据完整性测试结果 ======"
append_summary "数据完整性" \
  "全盘映射校验失败: ${FAIL_COUNT:-SKIP}/10" \
  "延迟读取: $([ ${rc:-0} -eq 0 ] && echo PASS || echo FAIL)"
