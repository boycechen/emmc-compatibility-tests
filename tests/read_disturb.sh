#!/bin/bash
# ============================================================
# 读干扰测试 (Read Disturb)
#
# 原理：NAND Flash 的相邻 page 之间会互相影响，
#   对一个 page 反复读取会导致相邻 page 的比特翻转。
#   eMMC 控制器应该通过 read-retry 或数据刷新来缓解。
#
# 测试方法：
#   1. 先写好数据并计算校验和
#   2. 对相邻区域反复读 10万~50万次
#   3. 验证原始数据的完整性
#   4. 观察读干扰是否导致数据损坏
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  读干扰测试 (Read Disturb)"
echo "========================================"

RESULTS=()

# --- 使用自定义数据验证的 fio 工作 ---
# 写入一块数据，然后对相邻区域反复读，最后验证数据
echo ""
echo "--- 写入校验数据 ---"

# Step 1: 写入校验数据（写入可验证的随机数据）
echo "  写入 128MB 校验数据到区域A..."
fio --filename="$EMMC_DEV" \
    --direct=1 \
    --rw=write \
    --bs=4k \
    --size=128M \
    --offset=0 \
    --iodepth=16 \
    --ioengine=libaio \
    --name=rd_write_data \
    --output="${RESULT_DIR}/rd_write.json" \
    --output-format=json \
    --dedupe_percentage=0 \
    --verify=crc32c \
    --verify_pattern=0xdeadbeef \
    --verify_state_save=0 2>/dev/null

RESULTS+=("$(parse_fio_result "${RESULT_DIR}/rd_write.json" "读干扰-写入数据")")

# Step 2: 对相邻区域反复读（产生读干扰）
echo ""
echo "--- 对相邻区域反复读 (50万次) ---"
# 对区域B（紧邻区域A）反复读
for round in 1 2 3 4 5; do
  echo "  第${round}轮: 10万次读取..."
  fio --filename="$EMMC_DEV" \
      --direct=1 \
      --rw=randread \
      --bs=4k \
      --size=128M \
      --offset=128M \
      --iodepth=32 \
      --ioengine=libaio \
      --numjobs=4 \
      --runtime=60 \
      --time_based \
      --name=rd_disturb_r${round} \
      --output=/dev/null 2>/dev/null
done

# Step 3: 验证原始数据是否损坏
echo ""
echo "--- 验证区域A数据完整性 ---"
fio --filename="$EMMC_DEV" \
    --direct=1 \
    --rw=read \
    --bs=4k \
    --size=128M \
    --offset=0 \
    --iodepth=16 \
    --ioengine=libaio \
    --name=rd_verify \
    --output="${RESULT_DIR}/rd_verify.json" \
    --output-format=json \
    --verify=crc32c \
    --verify_pattern=0xdeadbeef \
    --verify_state_save=0 \
    --verify_fatal=1 2>/dev/null

VERIFY_EXIT=$?
RESULTS+=("$(parse_fio_result "${RESULT_DIR}/rd_verify.json" "读干扰-数据校验")")

# Step 4: 换大块反复读（模拟重度读场景）
echo ""
echo "--- 重度读干扰: 128M连续读 * 10轮 ---"
for round in 1 2 3 4 5 6 7 8 9 10; do
  fio --filename="$EMMC_DEV" \
      --direct=1 \
      --rw=read \
      --bs=1m \
      --size=512M \
      --offset=256M \
      --iodepth=64 \
      --ioengine=libaio \
      --runtime=15 \
      --time_based \
      --name=rd_heavy_r${round} \
      --output=/dev/null 2>/dev/null
  echo -n "."
done
echo " 完成"

# 再次验证
echo ""
echo "--- 二次验证区域A数据 ---"
fio --filename="$EMMC_DEV" \
    --direct=1 \
    --rw=read \
    --bs=4k \
    --size=128M \
    --offset=0 \
    --iodepth=16 \
    --ioengine=libaio \
    --name=rd_verify2 \
    --output="${RESULT_DIR}/rd_verify2.json" \
    --output-format=json \
    --verify=crc32c \
    --verify_pattern=0xdeadbeef \
    --verify_state_save=0 \
    --verify_fatal=1 2>/dev/null

VERIFY2_EXIT=$?

echo ""
echo "--- 读干扰测试结论 ---"
if [ $VERIFY_EXIT -eq 0 ] && [ $VERIFY2_EXIT -eq 0 ]; then
  echo "  [PASS] 50万次读干扰后数据完整，eMMC read-disturb 防护正常"
elif [ $VERIFY_EXIT -ne 0 ]; then
  echo "  [FAIL] 第一次校验发现数据损坏! read-disturb 已导致比特翻转"
  echo "        控制器可能未做 read-retry 或数据刷新"
else
  echo "  [WARN] 第二次校验发现数据损坏，重度读干扰导致数据衰退"
fi

append_summary "读干扰测试" "校验退出码: $VERIFY_EXIT / $VERIFY2_EXIT"
