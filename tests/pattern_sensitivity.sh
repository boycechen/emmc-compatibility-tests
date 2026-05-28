#!/bin/bash
# ============================================================
# 数据 Pattern 敏感性测试 (Pattern Sensitivity)
#
# 原理：NAND Flash 的 cell-to-cell 干扰与写入的数据模式相关。
#   某些数据模式(如 checkerboard 0xAA)会在相邻 cell 间
#   产生更大干扰, 导致比特错误率上升。eMMC 控制器通过
#   ECC + data scrambling 来缓解, 但实现有 bug 时会漏过。
#
# 测试方式：写特定数据模式 → 读回 CRC 校验
#   每种模式写入 512MB, 立即读回验证
#   覆盖: 全0, 全1, checkboard, walking bit, 随机
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  NAND Pattern 敏感性测试"
echo "========================================"
reset_device

RESULTS=()
SIZE=512M
PATTERNS=(
  "0x00000000 全0(最大program压力)"
  "0xffffffff 全1(擦除态)"
  "0xaaaaaaaa Checkerboard"
  "0x55555555 反向Checkerboard"
  "0x99669966 伪随机pattern1"
  "0x12345678 伪随机pattern2"
  "0xdeadbeef 固定魔数"
)

echo ""
echo "--- 各 Pattern 写入+校验 ---"
echo "  (每次写入 512MB, 写后立即读回校验)"
echo ""

FAIL_PATTERN=0

for entry in "${PATTERNS[@]}"; do
  pat=$(echo "$entry" | awk '{print $1}')
  label=$(echo "$entry" | cut -d' ' -f2-)

  echo -n "  pattern=$pat ($label) ... "
  rc=0

  fio --filename="$EMMC_DEV" --direct=1 --rw=write --bs=4k --size=$SIZE \
      --iodepth=16 --ioengine=libaio --name=pat_w_${pat} \
      --output="${RESULT_DIR}/pat_write_${pat}.json" --output-format=json \
      --verify=crc32c --verify_pattern=$pat --verify_state_save=0 2>/dev/null || true

  fio --filename="$EMMC_DEV" --direct=1 --rw=read --bs=4k --size=$SIZE \
      --iodepth=16 --ioengine=libaio --name=pat_r_${pat} \
      --output="${RESULT_DIR}/pat_read_${pat}.json" --output-format=json \
      --verify=crc32c --verify_pattern=$pat --verify_state_save=0 --verify_fatal=1 \
      2>/dev/null || rc=$?

  if [ $rc -eq 0 ]; then
    echo "PASS"
  else
    echo "FAIL!"
    FAIL_PATTERN=$((FAIL_PATTERN + 1))
    echo "    [FAIL] pattern=$pat 校验失败, NAND cell干扰或scramble bug!"
  fi

  RESULTS+=("$(parse_fio_result "${RESULT_DIR}/pat_write_${pat}.json" "Pattern-${label}")")
done

echo ""
echo "--- 交叉 Pattern 残留测试 ---"
echo "  写入一种 Pattern, 用另一种 Pattern 读回"
echo "  (检测是否存在数据残留/干扰)"

# 写 0xAA, 读 0x55 (相邻互补pattern)
echo "  写 0xAA → 读 0x55 (预期校验失败, 检测错误报告)..."
fio --filename="$EMMC_DEV" --direct=1 --rw=write --bs=4k --size=128M \
    --iodepth=8 --ioengine=libaio --name=pat_cross_w \
    --output=/dev/null \
    --verify=crc32c --verify_pattern=0xaaaaaaaa --verify_state_save=0 2>/dev/null || true

rc=0
fio --filename="$EMMC_DEV" --direct=1 --rw=read --bs=4k --size=128M \
    --iodepth=8 --ioengine=libaio --name=pat_cross_r \
    --output="${RESULT_DIR}/pat_cross_read.json" --output-format=json \
    --verify=crc32c --verify_pattern=0x55555555 --verify_state_save=0 --verify_fatal=1 \
    2>/dev/null || rc=$?

if [ $rc -ne 0 ]; then
  echo "  [OK] 正确检测到 pattern 不匹配 (预期行为)"
else
  echo "  [WARN] 不同 pattern 校验通过? 可能存在数据残留问题!"
  FAIL_PATTERN=$((FAIL_PATTERN + 1))
fi

echo ""
echo "--- 长时 Pattern 稳定性 ---"
echo "  反复写/读 3 轮 checkerboard pattern..."
for round in 1 2 3; do
  echo -n "  第${round}轮 ... "
  rc=0
  fio --filename="$EMMC_DEV" --direct=1 --rw=write --bs=4k --size=$SIZE \
      --iodepth=16 --ioengine=libaio --name=pat_loop_w_${round} \
      --output=/dev/null \
      --verify=crc32c --verify_pattern=0xaaaaaaaa --verify_state_save=0 2>/dev/null || true
  fio --filename="$EMMC_DEV" --direct=1 --rw=read --bs=4k --size=$SIZE \
      --iodepth=16 --ioengine=libaio --name=pat_loop_r_${round} \
      --output=/dev/null \
      --verify=crc32c --verify_pattern=0xaaaaaaaa --verify_state_save=0 --verify_fatal=1 \
      2>/dev/null || rc=$?
  [ $rc -eq 0 ] && echo "PASS" || echo "FAIL"
done

echo ""
echo "====== Pattern 敏感性测试结果 ======"
if [ $FAIL_PATTERN -eq 0 ]; then
  echo "  [PASS] 所有 pattern 校验通过, NAND scrambler/ECC 正常"
else
  echo "  [FAIL] ${FAIL_PATTERN} 个 pattern 校验失败!"
fi

for r in "${RESULTS[@]}"; do echo "  $r"; done
append_summary "Pattern敏感性" "失败: ${FAIL_PATTERN}"
