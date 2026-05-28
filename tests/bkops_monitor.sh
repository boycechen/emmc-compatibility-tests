#!/bin/bash
# ============================================================
# BKOPS 后台操作监测 (Background Ops Monitor)
#
# 原理：eMMC 4.5+ 支持 Background Operations, 允许控制器
#   在空闲时间自行执行 GC/磨损均衡/数据刷新。
#   BKOPS_EN (EXT_CSD[502]) 控制使能。
#
#   BKOPS 期间的延迟尖峰是已知问题:
#   - 前台 IO 被 BKOPS 阻塞 (spec 定义最多 60s)
#   - 频繁 BKOPS 导致吞吐量不稳定
#   - BKOPS 与 cache flush 交互导致死锁
#   - BKOPS 未被正确触发 → GC 累积 → 性能悬崖
#
# 测试方式:
#   1. 读取 BKOPS 状态寄存器
#   2. 连续写压力后监测 BKOPS 触发
#   3. 空闲期延迟监测 (BKOPS 可能后台活动)
#   4. BKOPS 频率对延迟尖峰的影响
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  BKOPS 后台操作监测"
echo "========================================"
reset_device

RESULTS=()
FAIL_COUNT=0
DEV_NAME=$(basename "$EMMC_DEV")
WARN_COUNT=0
BKOPS_LOG="${LOG_DIR}/bkops_events.log"

# ---------- 检测 BKOPS 支持 ----------
EXT_CSD=$(mmc extcsd read "$EMMC_DEV" 2>/dev/null)
BKOPS_SUP=$(echo "$EXT_CSD" | grep "\[502\]" | awk '{print $NF}')

if [ "$BKOPS_SUP" != "1" ]; then
  echo "  [SKIP] 设备不支持 BKOPS"
  append_summary "BKOPS" "SKIP-不支持"
  exit 0
fi

BKOPS_EN=$(echo "$EXT_CSD" | grep "\[163\]" | awk '{print $NF}')
echo ""
echo "  BKOPS_SUPPORT[502] = $BKOPS_SUP (支持)"
echo "  BKOPS_EN[163]      = $BKOPS_EN $( [ "$BKOPS_EN" = "1" ] && echo '(自动)' || echo '(手动)')"

# ---------- 阶段1: 写后 BKOPS 状态 ----------
echo ""
echo "--- 阶段1: 写压力后 BKOPS 状态 ---"
echo "  写入 2GB 数据触发 GC/BKOPS..."

fio --filename="$EMMC_DEV" --direct=1 --rw=write --bs=1m --size=2G \
    --iodepth=8 --ioengine=libaio --name=bkops_write \
    --output="${RESULT_DIR}/bkops_write.json" --output-format=json \
    2>/dev/null || true

# 等待 BKOPS 可能触发
sleep 3

BKOPS_STATUS=$(echo "$EXT_CSD" | grep "\[246\]" | awk '{print $NF}')
echo "  BKOPS_STATUS[246] = ${BKOPS_STATUS:-N/A}"
echo "  (非0表示BKOPS正在执行)"

RESULTS+=("$(parse_fio_result "${RESULT_DIR}/bkops_write.json" "BKOPS写压力")")

# ---------- 阶段2: 空闲期延迟监测 ----------
echo ""
echo "--- 阶段2: 空闲期延迟监测 ---"
echo "  每 200ms 发单次读, 监测延迟分布..."
echo "  (BKOPS 后台活动期间读延迟会显著升高)"

fio --filename="$EMMC_DEV" --direct=1 --rw=read --bs=4k --size=512M \
    --iodepth=1 --ioengine=libaio --rate_iops=5 --thinktime=200ms \
    --runtime=120 --time_based --name=bkops_lat \
    --output="${RESULT_DIR}/bkops_lat.json" --output-format=json \
    --write_lat_log="${LOG_DIR}/bkops_lat" --log_avg_msec=1000 \
    2>/dev/null || true
RESULTS+=("$(parse_fio_result "${RESULT_DIR}/bkops_lat.json" "BKOPS空闲监测")")

# 分析延迟尖峰
echo ""
echo "--- 延迟尖峰分析 ---"
python3 << PYEOF
import statistics, os, re

log_dir = "$LOG_DIR"
log_file = os.path.join(log_dir, "bkops_lat_clat.log")
if os.path.exists(log_file):
    lats = []
    with open(log_file) as f:
        for line in f:
            parts = line.strip().split(',')
            if len(parts) >= 3 and parts[2].isdigit():
                lats.append(int(parts[2]))

    if len(lats) > 10:
        avg = statistics.mean(lats)
        p99 = sorted(lats)[int(len(lats) * 0.99)]
        p999 = sorted(lats)[int(len(lats) * 0.999)]
        spikes = [l for l in lats if l > p99 * 3]
        print(f"  采样数: {len(lats)}")
        print(f"  平均延迟: {avg:.0f} us")
        print(f"  P99:      {p99} us")
        print(f"  P99.9:    {p999} us")
        print(f"  尖峰数(>3×P99): {len(spikes)} ({len(spikes)*100/len(lats):.1f}%)")
        if len(spikes) > len(lats) * 0.05:
            print("  [WARN] 尖峰比例 > 5%, 可能存在 BKOPS 干扰!")
        else:
            print("  [PASS] 延迟分布正常")
    else:
        print("  延迟数据不足")
else:
    print("  无延迟日志")
PYEOF

# ---------- 阶段3: BKOPS 使能/禁用时对比 ----------
echo ""
echo "--- 阶段3: BKOPS 使能状态对比 ---"
echo "  检查 BKOPS 是否被正确配置..."

# 读取 BKOPS_EN
NEW_STATUS=$(mmc extcsd read "$EMMC_DEV" 2>/dev/null | grep "\[163\]" | awk '{print $NF}')
echo "  BKOPS_EN[163] 当前值: $NEW_STATUS"
echo "  (1=自动使能, 0=禁用)"

if [ "$NEW_STATUS" = "0" ] && [ "$BKOPS_SUP" = "1" ]; then
  echo "  [WARN] 设备支持 BKOPS 但被禁用！系统可能未配置"
  WARN_COUNT=$((WARN_COUNT + 1))
fi

# ---------- 阶段4: 长时写后空闲延迟 ----------
echo ""
echo "--- 阶段4: 大量写后空闲延迟 ---"
echo "  写 4GB 后立即监测空闲读延迟 (BKOPS 可能后台生效)..."

# 用固定 range 反复写让 GC 累积
fio --filename="$EMMC_DEV" --direct=1 --rw=write --bs=1m --size=4G \
    --iodepth=8 --ioengine=libaio --name=bkops_big \
    --output="${RESULT_DIR}/bkops_big.json" --output-format=json \
    2>/dev/null || true

sleep 2

rc=0
fio --filename="$EMMC_DEV" --direct=1 --rw=read --bs=4k --size=64M \
    --iodepth=1 --ioengine=libaio --name=bkops_gc_check \
    --output="${RESULT_DIR}/bkops_gc_check.json" --output-format=json \
    --verify=crc32c --verify_pattern=0xdeadbeef --verify_state_save=0 --verify_fatal=1 \
    2>/dev/null || rc=$?
echo -n "  大量写后读校验: "
[ $rc -eq 0 ] && echo "PASS" || { echo "FAIL! (BKOPS 期间数据损坏?)"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

echo ""
echo "====== BKOPS 监测结果 ======"
echo "  BKOPS_SUPPORT:   $BKOPS_SUP"
echo "  BKOPS_EN:        ${NEW_STATUS:-$BKOPS_EN}"
echo "  告警: ${WARN_COUNT:-0}"

for r in "${RESULTS[@]}"; do echo "  $r"; done
append_summary "BKOPS" "失败: ${FAIL_COUNT}"
