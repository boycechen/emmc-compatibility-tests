#!/bin/bash
# ============================================================
# 长时间浸泡测试 (Long-haul Soak Test)
#
# 原理：许多 eMMC 固件 bug 只在长时间运行后才会暴露：
#   - 内存泄漏: 内部 SRAM 或 buffer 随着时间耗尽
#   - 定时器溢出: 内部计数器溢出导致调度异常
#   - 映射表膨胀: 碎片化累积导致 GC 效率下降
#   - 物理损伤累积: ECC 校正计数递增但未被监测
#
# 测试方式：6 小时混合负载, 每 15 分钟记录一次性能,
#   检测性能衰减、延迟异常、错误计数变化。
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  长时浸泡测试 (Long-haul Soak)"
echo "========================================"
reset_device

RESULTS=()
DEV_NAME=$(basename "$EMMC_DEV")
TOTAL_DURATION=21600  # 6 小时
CHECK_INTERVAL=900    # 每 15 分钟检查一次
LOOPS=$((TOTAL_DURATION / CHECK_INTERVAL))
SNAPSHOT_LOG="${LOG_DIR}/soak_snapshots.log"

echo ""
echo "  总时长: $((TOTAL_DURATION / 3600)) 小时"
echo "  检查间隔: $((CHECK_INTERVAL / 60)) 分钟"
echo "  检查点数: $LOOPS"
echo ""

# 启动后台混合负载
echo "--- 启动混合负载 ---"
fio --filename="$EMMC_DEV" --direct=1 --rw=randrw --rwmixread=70 \
    --bs=4k --size=50% --iodepth=8 --numjobs=2 --ioengine=libaio \
    --group_reporting --runtime=$TOTAL_DURATION --time_based --ramp_time=30 \
    --name=soak_load \
    --write_bw_log="${LOG_DIR}/soak_bw" \
    --write_iops_log="${LOG_DIR}/soak_iops" \
    --write_lat_log="${LOG_DIR}/soak_lat" \
    --output="${RESULT_DIR}/soak_result.json" --output-format=json \
    --log_avg_msec=60000 2>/dev/null &
FIO_PID=$!

# 定期快照
echo ""
echo "--- 定期快照 ---"
: > "$SNAPSHOT_LOG"
echo "# time_elapsed bw_read bw_write iops_read iops_write err_cnt" >> "$SNAPSHOT_LOG"

for i in $(seq 1 $LOOPS); do
  sleep $CHECK_INTERVAL

  # 检查 fio 是否还在运行
  kill -0 $FIO_PID 2>/dev/null || break

  # 读取硬件错误计数
  ERR_COUNT=0
  for path in /sys/block/${DEV_NAME}/device/*_errors /sys/block/${DEV_NAME}/device/*_failures; do
    [ -f "$path" ] && ERR_COUNT=$((ERR_COUNT + $(cat "$path" 2>/dev/null || echo 0)))
  done

  # 记录快照
  ELAPSED=$((i * CHECK_INTERVAL))
  echo "[$((ELAPSED / 60))min] 错误计数: $ERR_COUNT"

  if [ "$i" -eq 1 ]; then
    INIT_ERR=$ERR_COUNT
  fi

  # 在中间和结束时做数据校验
  if [ "$i" -eq "$LOOPS" ] || [ "$i" -eq $((LOOPS / 2)) ]; then
    echo "  执行数据校验..."
    rc=0
    fio --filename="$EMMC_DEV" --direct=1 --rw=randread --bs=4k --size=256M \
        --iodepth=4 --ioengine=libaio --name=soak_check_${i} \
        --output="${RESULT_DIR}/soak_check_${i}.json" --output-format=json 2>/dev/null || true
    RESULTS+=("$(parse_fio_result "${RESULT_DIR}/soak_check_${i}.json" "浸泡${i}轮检查")")
  fi
done

# 等待 fio 完成
wait $FIO_PID 2>/dev/null
echo "  混合负载完成"

# 最终校验
echo ""
echo "--- 最终数据校验 ---"
fio --filename="$EMMC_DEV" --direct=1 --rw=write --bs=4k --size=512M \
    --iodepth=16 --ioengine=libaio --name=soak_final_w \
    --output="${RESULT_DIR}/soak_final_write.json" --output-format=json \
    --verify=crc32c --verify_pattern=0xbeef --verify_state_save=0 2>/dev/null || true

rc=0
fio --filename="$EMMC_DEV" --direct=1 --rw=read --bs=4k --size=512M \
    --iodepth=16 --ioengine=libaio --name=soak_final_r \
    --output="${RESULT_DIR}/soak_final_read.json" --output-format=json \
    --verify=crc32c --verify_pattern=0xbeef --verify_state_save=0 --verify_fatal=1 \
    2>/dev/null || rc=$?
[ $rc -eq 0 ] && echo "  [PASS] 最终校验通过" || echo "  [FAIL] 最终校验失败!"

# 总错误计数变化
echo ""
echo "--- 错误计数变化 ---"
FINAL_ERR=0
for path in /sys/block/${DEV_NAME}/device/*_errors /sys/block/${DEV_NAME}/device/*_failures; do
  [ -f "$path" ] && FINAL_ERR=$((FINAL_ERR + $(cat "$path" 2>/dev/null || echo 0)))
done
echo "  初始错误: ${INIT_ERR:-0}"
echo "  最终错误: ${FINAL_ERR}"
echo "  新增错误: $((FINAL_ERR - INIT_ERR))"
if [ $((FINAL_ERR - INIT_ERR)) -gt 0 ]; then
  echo "  [WARN] 长时间运行后出现了硬件错误!"
fi

echo ""
echo "--- 性能衰减分析 ---"
python3 << PYEOF
import statistics, os

log_dir = "$LOG_DIR"
bws = []
log_path = os.path.join(log_dir, 'soak_bw.log')
if os.path.exists(log_path):
    with open(log_path) as f:
        for line in f:
            parts = line.strip().split(',')
            if len(parts) >= 2 and parts[1].isdigit():
                bws.append(int(parts[1]))

if len(bws) > 10:
    half = len(bws) // 3
    first_avg = statistics.mean(bws[:half])
    last_avg = statistics.mean(bws[-half:])
    print(f"  采样点数: {len(bws)}")
    print(f"  前1/3平均带宽: {first_avg:.0f} KB/s")
    print(f"  后1/3平均带宽: {last_avg:.0f} KB/s")
    if first_avg > 0:
        decay = (1 - last_avg/first_avg) * 100
        print(f"  性能衰减: {decay:.1f}%")
        if decay > 20:
            print(f"  [FAIL] 性能衰减 > 20%, 可能存在资源泄漏")
        elif decay > 10:
            print(f"  [WARN] 性能衰减 > 10%, 需关注")
        else:
            print(f"  [PASS] 性能稳定")
else:
    print("  无足够带宽数据")
PYEOF

echo ""
echo "====== 长时浸泡测试结果 ======"
echo "  总耗时: $((TOTAL_DURATION / 3600)) 小时"
echo "  fio 退出码: $(wait $FIO_PID 2>/dev/null; echo $?)"

for r in "${RESULTS[@]}"; do echo "  $r"; done
append_summary "长时浸泡" \
  "新增错误: $((FINAL_ERR - INIT_ERR))"
