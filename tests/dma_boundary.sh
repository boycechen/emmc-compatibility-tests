#!/bin/bash
# ============================================================
# DMA 地址边界跨越测试 (DMA Boundary Crossing)
#
# 原理：RK3588 DWC MMC 控制器内部 DMA 引擎对传输地址有对齐
#   要求。当一次 DMA 传输跨越特定地址边界时：
#   - 某些版本控制器可能拆分错误
#   - 内部 DMA 描述符链表构造异常
#   - 数据被写入错误位置或损坏
#
#   历史已知问题边界 (与具体 DMA 实现相关):
#   - 64KB (常见 DMA 描述符边界)
#   - 128KB (AHB/AXI burst 边界)
#   - 1MB (某些控制器内部页表)
#   - 4MB (TTBR 或 SMMU 页表)
#
# 测试方式：在边界前 4KB 处写入 8KB 数据 (跨越边界)，
#   然后读回校验。每个边界测试 3 种块大小。
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  DMA 地址边界跨越测试"
echo "========================================"
reset_device

RESULTS=()
FAIL_COUNT=0

# 要测试的边界 (bytes)
BOUNDARIES=(65536 131072 262144 524288 1048576 2097152 4194304 16777216 67108864)
# 每种边界测试的块大小 (在边界前后分别放数据)
BS_LIST=(4096 8192 16384 32768)
TOTAL=$(( ${#BOUNDARIES[@]} * ${#BS_LIST[@]} ))
CUR=0

echo ""
echo "  测试 ${#BOUNDARIES[@]} 个边界 × ${#BS_LIST[@]} 个块大小 = ${TOTAL} 种组合"
echo ""

for BOUNDARY in "${BOUNDARIES[@]}"; do
  for BS in "${BS_LIST[@]}"; do
    CUR=$((CUR + 1))
    OFFSET=$((BOUNDARY - 4096))        # 边界前 4KB
    if [ $OFFSET -lt 0 ]; then
      continue
    fi
    # 需要 ensure offset+bs < boundary + boundary_gap (no overlap)
    END=$((OFFSET + BS))

    # 写:
    #   offset = BOUNDARY - 4K, 跨越边界长度 = 4K + (BS - 4K) = BS
    #   如果 BS=4K, offset+4K = boundary, 刚好到边界
    #   如果 BS=8K, offset+8K = boundary+4K, 跨过边界 4K
    #   如果 BS=16K, offset+16K = boundary+12K, 跨过边界 12K
    #   如果 BS=32K, offset+32K = boundary+28K, 跨过边界 28K

    PCT=$((CUR * 100 / TOTAL))
    echo -ne "  [${PCT}%] 边界=$(numfmt --to=iec $BOUNDARY)  bs=$(numfmt --to=iec $BS)  offset=$(numfmt --to=iec $OFFSET) ... "

    rc=0
    fio --filename="$EMMC_DEV" --direct=1 --rw=write --bs=$BS --size=$BS \
        --offset=$OFFSET --iodepth=16 --ioengine=libaio \
        --name=dma_w_${BOUNDARY}_${BS} \
        --output="${RESULT_DIR}/dma_w_${BOUNDARY}_${BS}.json" --output-format=json \
        --verify=crc32c --verify_pattern=0xa5a5a5a5 --verify_state_save=0 \
        2>/dev/null || rc=$?

    if [ $rc -ne 0 ]; then
      echo "写入失败!"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      continue
    fi

    rc=0
    fio --filename="$EMMC_DEV" --direct=1 --rw=read --bs=$BS --size=$BS \
        --offset=$OFFSET --iodepth=16 --ioengine=libaio \
        --name=dma_v_${BOUNDARY}_${BS} \
        --output="${RESULT_DIR}/dma_v_${BOUNDARY}_${BS}.json" --output-format=json \
        --verify=crc32c --verify_pattern=0xa5a5a5a5 --verify_state_save=0 --verify_fatal=1 \
        2>/dev/null || rc=$?

    if [ $rc -eq 0 ]; then
      echo "PASS"
    else
      echo "FAIL (DMA 边界!" 
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
  done
done

echo ""
echo "--- 边界扫描路径回读 ---"
echo "  在边界处随机读取并验证..."

# 使用固定 pattern 写满 256MB 跨边界区域
BIG_SIZE=256M
fio --filename="$EMMC_DEV" --direct=1 --rw=write --bs=4k --size=$BIG_SIZE \
    --offset=$((64 * 1024)) --iodepth=8 --ioengine=libaio \
    --name=dma_big_w \
    --output="${RESULT_DIR}/dma_big_w.json" --output-format=json \
    --verify=crc32c --verify_pattern=0xdeadbeef --verify_state_save=0 \
    2>/dev/null || true

rc=0
fio --filename="$EMMC_DEV" --direct=1 --rw=randread --bs=4k --size=$BIG_SIZE \
    --offset=$((64 * 1024)) --iodepth=1 --ioengine=libaio \
    --name=dma_big_v \
    --output="${RESULT_DIR}/dma_big_v.json" --output-format=json \
    --verify=crc32c --verify_pattern=0xdeadbeef --verify_state_save=0 --verify_fatal=1 \
    2>/dev/null || rc=$?
echo -n "  跨边界随机读校验: "
[ $rc -eq 0 ] && echo "PASS" || { echo "FAIL!"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

echo ""
echo "====== DMA 边界测试结果 ======"
if [ $FAIL_COUNT -eq 0 ]; then
  echo "  [PASS] 所有 DMA 边界校验通过"
else
  echo "  [FAIL] ${FAIL_COUNT} 个 DMA 边界检查点失败!"
fi
append_summary "DMA边界" "失败: ${FAIL_COUNT}"
