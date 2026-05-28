#!/bin/bash
# ============================================================
# LBA 映射表压力测试 (LBA Remap Stress)
#
# 原理：eMMC FTL 将逻辑地址映射到 NAND 物理地址。
#   映射表存储在控制器内部 SRAM/DRAM。当：
#   - 大量分散 LBA 被写入 → 映射表缓存 thrashing
#   - 同一 LBA 被反复改写 → GC 必须搬移并更新映射
#   - 多线程并发访问不同 LBA 区域 → 映射表并发竞争
#   控制器实现有 bug 时会出现：数据混乱、挂起、性能崩塌
#
# 测试方式：
#   1. 写入 200 个分散 8MB 区域 (间隔均匀分布全盘)
#   2. 全部读回校验 (验证映射正确性)
#   3. 用不同 pattern 再次写入相同区域 + 校验
#   4. 多线程并发随机访问 + 最终一致性校验
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  LBA 映射表压力测试"
echo "========================================"
reset_device

RESULTS=()
DEV_NAME=$(basename "$EMMC_DEV")
DEV_SIZE=$(blockdev --getsize64 "$EMMC_DEV")
REGION_SIZE=$((8 * 1024 * 1024))  # 8MiB per region
REGION_SIZE=$((REGION_SIZE - (REGION_SIZE % 4096)))
REGION_COUNT=200
STRIDE=$((DEV_SIZE / REGION_COUNT))
STRIDE=$((STRIDE - (STRIDE % 4096)))
TOTAL_WRITE=$((REGION_COUNT * REGION_SIZE))

echo ""
echo "  设备大小:   $(numfmt --to=iec $DEV_SIZE)"
echo "  分散区域:   ${REGION_COUNT} 个 × $(numfmt --to=iec ${REGION_SIZE})"
echo "  区域间隔:   $(numfmt --to=iec ${STRIDE})"
echo "  总写入量:   $(numfmt --to=iec ${TOTAL_WRITE})"
echo ""

# ---- 阶段1: 多Job分散写入 (带CRC校验) ----
echo "--- 阶段1: 分散写入 (${REGION_COUNT}jobs × ${REGION_SIZE}) ---"
rc=0
fio --filename="$EMMC_DEV" --direct=1 --rw=write --bs=4k --size=$REGION_SIZE \
    --iodepth=8 --ioengine=libaio --numjobs=$REGION_COUNT \
    --offset_increment=$STRIDE --group_reporting \
    --name=remap_w1 \
    --output="${RESULT_DIR}/remap_w1.json" --output-format=json \
    --verify=crc32c --verify_pattern=0x5a5a5a5a --verify_state_save=0 \
    2>/dev/null || rc=$?
echo -n "  阶段1写入: "
[ $rc -eq 0 ] && echo "OK" || echo "FAIL (rc=$rc)"
RESULTS+=("$(parse_fio_result "${RESULT_DIR}/remap_w1.json" "阶段1-分散写入")")

# 阶段1 校验
rc=0
fio --filename="$EMMC_DEV" --direct=1 --rw=read --bs=4k --size=$REGION_SIZE \
    --iodepth=8 --ioengine=libaio --numjobs=$REGION_COUNT \
    --offset_increment=$STRIDE --group_reporting \
    --name=remap_v1 \
    --output="${RESULT_DIR}/remap_v1.json" --output-format=json \
    --verify=crc32c --verify_pattern=0x5a5a5a5a --verify_state_save=0 --verify_fatal=1 \
    2>/dev/null || rc=$?
echo -n "  阶段1校验: "
[ $rc -eq 0 ] && echo "PASS" || echo "FAIL (映射表查询异常!)"
RESULTS+=("$(parse_fio_result "${RESULT_DIR}/remap_v1.json" "阶段1-校验")")

# ---- 阶段2: 二次写入 (不同pattern, 强制FTL remap) ----
echo ""
echo "--- 阶段2: 同区域二次写入 + 校验 ---"
echo "  新 pattern 强制 FTL 分配新物理块, 原映射表需更新..."
rc=0
fio --filename="$EMMC_DEV" --direct=1 --rw=write --bs=4k --size=$REGION_SIZE \
    --iodepth=8 --ioengine=libaio --numjobs=$REGION_COUNT \
    --offset_increment=$STRIDE --group_reporting \
    --name=remap_w2 \
    --output="${RESULT_DIR}/remap_w2.json" --output-format=json \
    --verify=crc32c --verify_pattern=0xa5a5a5a5 --verify_state_save=0 \
    2>/dev/null || rc=$?
echo -n "  阶段2重写: "
[ $rc -eq 0 ] && echo "OK" || echo "FAIL (rc=$rc)"

rc=0
fio --filename="$EMMC_DEV" --direct=1 --rw=read --bs=4k --size=$REGION_SIZE \
    --iodepth=8 --ioengine=libaio --numjobs=$REGION_COUNT \
    --offset_increment=$STRIDE --group_reporting \
    --name=remap_v2 \
    --output="${RESULT_DIR}/remap_v2.json" --output-format=json \
    --verify=crc32c --verify_pattern=0xa5a5a5a5 --verify_state_save=0 --verify_fatal=1 \
    2>/dev/null || rc=$?
echo -n "  阶段2校验: "
[ $rc -eq 0 ] && echo "PASS" || echo "FAIL (FTL remap后数据异常!)"
RESULTS+=("$(parse_fio_result "${RESULT_DIR}/remap_v2.json" "阶段2-二次校验")")

# ---- 阶段3: 区域间随机跳转 + 并发 ----
echo ""
echo "--- 阶段3: 多线程区域间随机跳转 ---"
echo "  4 线程在区域间并发随机读写, 检测映射表并发竞争..."
rc=0
fio --filename="$EMMC_DEV" --direct=1 --rw=randrw --rwmixread=70 \
    --bs=4k --size=$TOTAL_WRITE --iodepth=4 --numjobs=4 --ioengine=libaio \
    --offset_increment=$((STRIDE / 4)) --group_reporting \
    --runtime=90 --time_based --ramp_time=10 \
    --name=remap_stress \
    --output="${RESULT_DIR}/remap_stress.json" --output-format=json \
    2>/dev/null || rc=$?
echo -n "  并发随机跳转: "
[ $rc -eq 0 ] && echo "OK" || echo "FAIL (rc=$rc)"
RESULTS+=("$(parse_fio_result "${RESULT_DIR}/remap_stress.json" "阶段3-并发映射")")

# ---- 阶段4: 最终一致性校验 ----
echo ""
echo "--- 阶段4: 最终数据一致性校验 ---"
rc=0
fio --filename="$EMMC_DEV" --direct=1 --rw=read --bs=4k --size=$REGION_SIZE \
    --iodepth=8 --ioengine=libaio --numjobs=$REGION_COUNT \
    --offset_increment=$STRIDE --group_reporting \
    --name=remap_final \
    --output="${RESULT_DIR}/remap_final.json" --output-format=json \
    --verify=crc32c --verify_pattern=0xa5a5a5a5 --verify_state_save=0 --verify_fatal=1 \
    2>/dev/null || rc=$?
echo -n "  最终一致性: "
[ $rc -eq 0 ] && echo "PASS" || echo "FAIL (并发后数据损坏!)"
RESULTS+=("$(parse_fio_result "${RESULT_DIR}/remap_final.json" "阶段4-最终校验")")

echo ""
echo "====== LBA 映射表压力测试结果 ======"
for r in "${RESULTS[@]}"; do echo "  $r"; done

# dmesg 错误检查
echo ""
echo "--- dmesg 错误 ---"
dmesg | grep -iE "(mmc.*error|mmc.*fail|mmc.*timeout)" | tail -5 || echo "  (无)"
append_summary "LBA映射压力" "阶段: ${#RESULTS[@]}"
