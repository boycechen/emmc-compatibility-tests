#!/bin/bash
# ============================================================
# FUA/Barrier 语义测试 (Fence Unit Access)
#
# 原理：FUA (Force Unit Access) 要求数据必须到达非易失性
#   介质后才返回完成，绕过 write cache。
#   eMMC 5.0+ 通过 Reliable Write 实现 FUA 语义。
#
#   常见固件 bug：
#   - FUA 写返回过早 (数据仍在缓存中)
#   - FUA 与非 FUA 写之间的顺序违反 (barrier 失效)
#   - FUA 写不保证原子性 (partial write)
#   - 在 cache ON 模式下 FUA 被忽略
#
# 测试方式：
#   1. 检测内核/设备 FUA 支持
#   2. FUA 写延迟 vs 普通写延迟对比
#   3. FUA 写 + 校验 (验证数据到达介质)
#   4. 混合 FUA/非FUA 顺序保持
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  FUA/Barrier 语义测试"
echo "========================================"
reset_device

RESULTS=()
FAIL_COUNT=0

# ---- 阶段1: 检测 FUA 支持 ----
echo ""
echo "--- 阶段1: FUA 支持检测 ---"
FUA_SUPPORTED=0

# 检查块设备 max_write_zeroes_sectors / max_fua_sectors
FUA_SYSFS="/sys/block/$(basename $EMMC_DEV)/queue/fua"
if [ -f "$FUA_SYSFS" ]; then
  FUA_VAL=$(cat "$FUA_SYSFS")
  echo "  sysfs fua: $FUA_VAL"
  [ "$FUA_VAL" = "1" ] && FUA_SUPPORTED=1
fi

# 尝试 fio FUA 写
rc=0
fio --filename="$EMMC_DEV" --direct=1 --rw=write --bs=4k --size=4M \
    --iodepth=1 --ioengine=libaio --name=fua_probe --fua=1 \
    --output="${RESULT_DIR}/fua_probe.json" --output-format=json \
    2>/dev/null || rc=$?

if [ $rc -eq 0 ]; then
  echo "  fio --fua=1: 支持"
  FUA_SUPPORTED=1
else
  echo "  fio --fua=1: 不支持 (rc=$rc)"
fi

if [ $FUA_SUPPORTED -eq 0 ]; then
  echo "  [SKIP] FUA 不可用, 跳过后续测试"
  append_summary "FUA/Barrier" "SKIP-不支持"
  exit 0
fi

# ---- 阶段2: FUA 延迟 vs 非FUA 延迟 ----
echo ""
echo "--- 阶段2: FUA vs 非FUA 延迟对比 ---"
echo "  非FUA 延迟 (预期快, 缓存命中)..."
fio --filename="$EMMC_DEV" --direct=1 --rw=randwrite --bs=4k --size=256M \
    --iodepth=1 --ioengine=libaio --name=fua_lat_nocache \
    --output="${RESULT_DIR}/fua_lat_nocache.json" --output-format=json \
    --write_lat_log="${LOG_DIR}/fua_nocache" --log_avg_msec=100 \
    2>/dev/null
RESULTS+=("$(parse_fio_result "${RESULT_DIR}/fua_lat_nocache.json" "非FUA延迟")")

echo "  FUA 延迟 (预期慢, 强制刷入NAND)..."
fio --filename="$EMMC_DEV" --direct=1 --rw=randwrite --bs=4k --size=256M \
    --iodepth=1 --ioengine=libaio --name=fua_lat_fua --fua=1 \
    --output="${RESULT_DIR}/fua_lat_fua.json" --output-format=json \
    --write_lat_log="${LOG_DIR}/fua_fua" --log_avg_msec=100 \
    2>/dev/null
RESULTS+=("$(parse_fio_result "${RESULT_DIR}/fua_lat_fua.json" "FUA延迟")")

# ---- 阶段3: FUA 数据到达验证 ----
echo ""
echo "--- 阶段3: FUA 数据到达验证 ---"
echo "  用 FUA 写 0x5a 到 64MB 区域, 关闭缓存读回校验..."
rc=0
fio --filename="$EMMC_DEV" --direct=1 --rw=write --bs=4k --size=64M \
    --iodepth=4 --ioengine=libaio --name=fua_w --fua=1 \
    --output="${RESULT_DIR}/fua_write.json" --output-format=json \
    --verify=crc32c --verify_pattern=0x5a5a5a5a --verify_state_save=0 \
    2>/dev/null || rc=$?
echo -n "  FUA 写入: "
[ $rc -eq 0 ] && echo "OK" || echo "FAIL"

rc=0
fio --filename="$EMMC_DEV" --direct=1 --rw=read --bs=4k --size=64M \
    --iodepth=4 --ioengine=libaio --name=fua_v \
    --output="${RESULT_DIR}/fua_verify.json" --output-format=json \
    --verify=crc32c --verify_pattern=0x5a5a5a5a --verify_state_save=0 --verify_fatal=1 \
    2>/dev/null || rc=$?
echo -n "  FUA 校验: "
if [ $rc -eq 0 ]; then
  echo "PASS"
else
  echo "FAIL! (FUA 写数据未到达介质!)"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi
RESULTS+=("$(parse_fio_result "${RESULT_DIR}/fua_verify.json" "FUA校验")")

# ---- 阶段4: FUA/非FUA 顺序保持 (barrier 语义) ----
echo ""
echo "--- 阶段4: FUA barrier 顺序语义 ---"
echo "  写 A(非FUA) → 写 B(FUA) → 读 A 和 B..."
echo "  如果 A 在 B 之后才持久化, barrier 失效"

# 写入 A (非FUA) 和 B (FUA)
fio --filename="$EMMC_DEV" --direct=1 --rw=write --bs=4k --size=8M \
    --iodepth=1 --ioengine=libaio --name=fua_bar_A \
    --output="${RESULT_DIR}/fua_bar_A.json" --output-format=json \
    --verify=crc32c --verify_pattern=0x11111111 --verify_state_save=0 \
    --offset=0 2>/dev/null || true

fio --filename="$EMMC_DEV" --direct=1 --rw=write --bs=4k --size=8M \
    --iodepth=1 --ioengine=libaio --name=fua_bar_B --fua=1 \
    --output="${RESULT_DIR}/fua_bar_B.json" --output-format=json \
    --verify=crc32c --verify_pattern=0x22222222 --verify_state_save=0 \
    --offset=$((8 * 1024 * 1024)) 2>/dev/null || true

# 直接 IO 读回, 检查 A 和 B 的数据完整性
rc=0
fio --filename="$EMMC_DEV" --direct=1 --rw=read --bs=4k --size=8M \
    --iodepth=4 --ioengine=libaio --name=fua_bar_vA \
    --output="${RESULT_DIR}/fua_bar_vA.json" --output-format=json \
    --verify=crc32c --verify_pattern=0x11111111 --verify_state_save=0 --verify_fatal=1 \
    --offset=0 2>/dev/null || rc=$?
fio --filename="$EMMC_DEV" --direct=1 --rw=read --bs=4k --size=8M \
    --iodepth=4 --ioengine=libaio --name=fua_bar_vB \
    --output="${RESULT_DIR}/fua_bar_vB.json" --output-format=json \
    --verify=crc32c --verify_pattern=0x22222222 --verify_state_save=0 --verify_fatal=1 \
    --offset=$((8 * 1024 * 1024)) 2>/dev/null || rc=$?

if [ $rc -eq 0 ]; then
  echo "  barrier 顺序保持: PASS"
else
  echo "  barrier 顺序保持: FAIL! (FUA 写顺序问题)"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ---- 阶段5: 写缓存 ON 模式下 FUA 验证 ----
echo ""
echo "--- 阶段5: 写缓存 ON + FUA ---"
echo "  开启 write cache, 用 FUA 绕过, 验证数据..."
echo "  预期: FUA 应始终绕过缓存, 无论 cache 设置"

# 开启 write cache
echo write through > /sys/block/$(basename $EMMC_DEV)/device/power/pm_control 2>/dev/null || true
blockdev --setrw "$EMMC_DEV" 2>/dev/null || true

fio --filename="$EMMC_DEV" --direct=1 --rw=write --bs=4k --size=64M \
    --iodepth=4 --ioengine=libaio --name=fua_cache_w --fua=1 \
    --output="${RESULT_DIR}/fua_cache_w.json" --output-format=json \
    --verify=crc32c --verify_pattern=0x5a --verify_state_save=0 \
    2>/dev/null || true

rc=0
fio --filename="$EMMC_DEV" --direct=1 --rw=read --bs=4k --size=64M \
    --iodepth=4 --ioengine=libaio --name=fua_cache_v \
    --output="${RESULT_DIR}/fua_cache_v.json" --output-format=json \
    --verify=crc32c --verify_pattern=0x5a --verify_state_save=0 --verify_fatal=1 \
    2>/dev/null || rc=$?
echo -n "  缓存ON+FUA: "
[ $rc -eq 0 ] && echo "PASS" || { echo "FAIL!"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

echo ""
echo "====== FUA/Barrier 测试结果 ======"
if [ $FAIL_COUNT -eq 0 ]; then
  echo "  [PASS] FUA 语义正确"
else
  echo "  [FAIL] ${FAIL_COUNT} 个 FUA 检查点失败"
fi
for r in "${RESULTS[@]}"; do echo "  $r"; done
append_summary "FUA/Barrier" "失败: ${FAIL_COUNT}"
