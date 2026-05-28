#!/bin/bash
# ============================================================
# eMMC Sanitize 操作测试
#
# 原理：Sanitize (安全擦除) 通知 eMMC 物理擦除所有用户数据，
#   不同于 trim/discard (仅标记 FTL 映射无效)。
#   Sanitize 后所有用户数据应为 0 或 1 (取决于实现)。
#
# 检测目标：
#   - Sanitize 命令是否正常完成
#   - Sanitize 后数据是否被清除
#   - Sanitize 耗时 (异常超时 = 固件 bug)
#   - Sanitize 后设备是否能正常读写
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  Sanitize 操作测试"
echo "========================================"

RESULTS=()

echo ""
echo "--- 检查 Sanitize 支持 ---"
if ! command -v mmc &>/dev/null; then
  echo "  [SKIP] mmc-utils 未安装"
  exit 0
fi

# 检查 EXT_CSD 是否支持 sanitize
SANITIZE_SUPPORT=0
for dbg in /sys/kernel/debug/mmc*/mmc*/ext_csd; do
  [ -f "$dbg" ] || continue
  local sanitize_val=$(grep "EXT_CSD\[314\]" "$dbg" 2>/dev/null | awk '{print $NF}')
  # 检查 mmc-utils 输出
  break
done

if mmc extcsd read "$EMMC_DEV" 2>/dev/null | grep -qi "Sanitize"; then
  SANITIZE_SUPPORT=1
  echo "  [OK] 设备支持 Sanitize"
else
  # fallback: 检查 EXT_CSD[314] bit 0
  local raw=$(mmc extcsd read "$EMMC_DEV" 2>/dev/null | grep "EXT_CSD\[314\]" | awk '{print $NF}')
  if [ -n "$raw" ] && [ "$((raw & 1))" -eq 1 ]; then
    SANITIZE_SUPPORT=1
    echo "  [OK] 设备支持 Sanitize (EXT_CSD[314] bit0=1)"
  else
    echo "  [SKIP] 设备不支持 Sanitize"
    append_summary "Sanitize" "不支持"
    exit 0
  fi
fi

# 阶段1: 写入已知数据
echo ""
echo "--- 阶段1: 写入已知数据 ---"
echo "  写入 256MB 可校验数据..."
fio --filename="$EMMC_DEV" --direct=1 --rw=write --bs=4k --size=256M \
    --iodepth=16 --ioengine=libaio --name=sanitize_write \
    --output="${RESULT_DIR}/sanitize_before.json" --output-format=json \
    --verify=crc32c --verify_pattern=0x5a --verify_state_save=0 2>/dev/null || true

# 先验证写入成功 (确认数据落盘)
echo "  验证写入数据..."
rc=0
fio --filename="$EMMC_DEV" --direct=1 --rw=read --bs=4k --size=256M \
    --iodepth=16 --ioengine=libaio --name=sanitize_verify_before \
    --output=/dev/null \
    --verify=crc32c --verify_pattern=0x5a --verify_state_save=0 --verify_fatal=1 \
    2>/dev/null || rc=$?

if [ $rc -eq 0 ]; then
  echo "  [PASS] 写入数据校验通过"
else
  echo "  [FAIL] 写入阶段数据校验失败!"
  RESULTS+=("Sanitize: 写入阶段失败")
fi

# 阶段2: 执行 Sanitize
echo ""
echo "--- 阶段2: 执行 Sanitize ---"
echo "  正在安全擦除 (可能需要 10-60 秒)..."
START_SAN=$(date +%s)
if mmc sanitize "$EMMC_DEV" 2>/dev/null; then
  END_SAN=$(date +%s)
  SAN_DURATION=$((END_SAN - START_SAN))
  echo "  [PASS] Sanitize 完成, 耗时 ${SAN_DURATION}秒"

  if [ $SAN_DURATION -gt 120 ]; then
    echo "  [WARN] Sanitize 耗时 ${SAN_DURATION}秒 > 120秒, 异常偏慢"
  fi
else
  echo "  [FAIL] Sanitize 命令失败!"
  RESULTS+=("Sanitize: 命令失败")
fi

sleep 3

# 阶段3: Sanitize 后数据验证
echo ""
echo "--- 阶段3: Sanitize 后数据验证 ---"
echo "  读取 256MB 区域 (应全为 0 或特定值)..."

# 方式1: 尝试用 verify 读回 (预期数据已被擦除, 校验应该失败)
echo "  方式1: 校验读 (预期失败, 证明数据被擦除)..."
rc=0
fio --filename="$EMMC_DEV" --direct=1 --rw=read --bs=4k --size=256M \
    --iodepth=16 --ioengine=libaio --name=sanitize_verify_after \
    --output=/dev/null \
    --verify=crc32c --verify_pattern=0x5a --verify_state_save=0 --verify_fatal=1 \
    2>/dev/null || rc=$?

if [ $rc -ne 0 ]; then
  echo "    [PASS] Sanitize 成功擦除数据 (校验失败=预期中)"
else
  echo "    [WARN] Sanitize 后数据校验仍通过, 擦除可能无效!"
  RESULTS+=("Sanitize: 数据未被清除!")
fi

# 方式2: 抽样检查是否全零
echo "  方式2: 抽样检查全零 ..."
ZERO_COUNT=0
for sample in 0 1 2 3 4; do
  OFF=$((sample * 512))
  dd if="$EMMC_DEV" of="${LOG_DIR}/san_sample_${sample}.bin" bs=512 count=1 \
     skip=$OFF iflag=direct status=none 2>/dev/null || true
  if od -An -tx1 "${LOG_DIR}/san_sample_${sample}.bin" | grep -qv "00"; then
    ZERO_COUNT=$((ZERO_COUNT + 1))
  fi
  rm -f "${LOG_DIR}/san_sample_${sample}.bin"
done

if [ "$ZERO_COUNT" -eq 0 ]; then
  echo "    [PASS] Sanitize 后设备已清零"
elif [ "$ZERO_COUNT" -lt 5 ]; then
  echo "    [INFO] ${ZERO_COUNT}/5 样本非零 (部分eMMC初始化后返回特定pattern)"
else
  echo "    [WARN] 所有样本非零, Sanitize 可能未生效"
fi

# 阶段4: Sanitize 后性能恢复
echo ""
echo "--- 阶段4: Sanitize 后写入性能 ---"
fio --filename="$EMMC_DEV" --direct=1 --rw=write --bs=1m --size=512M \
    --iodepth=16 --ioengine=libaio --name=sanitize_perf \
    --output="${RESULT_DIR}/sanitize_perf.json" --output-format=json 2>/dev/null || true
RESULTS+=("$(parse_fio_result "${RESULT_DIR}/sanitize_perf.json" "Sanitize后写性能")")

echo ""
echo "====== Sanitize 测试结果 ======"
for r in "${RESULTS[@]}"; do echo "  $r"; done
append_summary "Sanitize" "耗时: ${SAN_DURATION:-N/A}秒, 结果: $([ ${#RESULTS[@]} -eq 0 ] && echo PASS || echo '见上')"
