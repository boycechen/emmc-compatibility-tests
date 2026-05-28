#!/bin/bash
# ============================================================
# 多线程竞态测试 (Multi-thread Contention)
#
# 原理：eMMC 内部只有一个通道(或有限通道)，
#   多线程并发的请求会在 FTL 层竞争资源。
#   某些固件在线程数增加时会出现：
#   - 读挨饿 (reader starvation): 写占满队列导致读延迟爆炸
#   - 写挨饿: 读请求占满导致写无法提交
#   - 死锁: 特定线程数/队列深度组合触发固件hang
#   - 优先级反转: FCFS/FIFO 导致高优请求被低优阻塞
#
# 测试设计：
#   用不同数量的读写线程并发，观察延迟分布变化
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  多线程竞态测试 (Contention)"
echo "========================================"
reset_device

SIZE="1G"
RESULTS=()
BG_PIDS=()

cleanup_bg() {
  [ ${#BG_PIDS[@]} -eq 0 ] || kill "${BG_PIDS[@]}" 2>/dev/null
  wait 2>/dev/null
  BG_PIDS=()
}
trap cleanup_bg EXIT INT TERM

echo ""
echo "--- 读挨饿测试 (Reader Starvation) ---"
echo "  原理: 大量写线程并发时，读请求是否能得到及时响应"

for writers in 1 2 4 8; do
  for readers in 1 2 4; do
    echo "  W=${writers} R=${readers} ..."

    # 启动写后台线程
    fio --filename="$EMMC_DEV" \
        --direct=1 \
        --rw=randwrite \
        --bs=4k \
        --size=$SIZE \
        --iodepth=4 \
        --numjobs=$writers \
        --ioengine=libaio \
        --group_reporting \
        --runtime=30 \
        --time_based \
        --name=starv_write_w${writers}_r${readers} \
        --output=/dev/null 2>/dev/null &

    WRITE_PID=$!
    BG_PIDS+=("$WRITE_PID")

    # 同时在读线程上测延迟
    fio --filename="$EMMC_DEV" \
        --direct=1 \
        --rw=randread \
        --bs=4k \
        --size=$SIZE \
        --iodepth=1 \
        --numjobs=$readers \
        --ioengine=libaio \
        --group_reporting \
        --runtime=30 \
        --time_based \
        --name=starv_read_w${writers}_r${readers} \
        --output="${RESULT_DIR}/starvation_r${readers}_w${writers}.json" \
        --output-format=json \
        --lat_percentiles=1 2>/dev/null

    wait $WRITE_PID 2>/dev/null

    RESULTS+=("$(parse_fio_result "${RESULT_DIR}/starvation_r${readers}_w${writers}.json" "竞态R${readers}W${writers}")")

    # 读延迟分析
    if [ -f "${RESULT_DIR}/starvation_r${readers}_w${writers}.json" ]; then
      python3 -c "
import json
d = json.load(open('${RESULT_DIR}/starvation_r${readers}_w${writers}.json'))
job = d.get('jobs', [{}])[0]
rd = job.get('read', {})
clat = rd.get('clat_ns', {}).get('percentile', {})
iops = rd.get('iops', 0)
if clat:
    p50 = clat.get('50.000000', 0)/1000
    p99 = clat.get('99.000000', 0)/1000
    p999 = clat.get('99.900000', 0)/1000
    print(f'    读延迟: P50={p50:.0f}us P99={p99:.0f}us P99.9={p999:.0f}us IOPS={iops}')
    # 检测读挨饿: P99.9 > 10ms
    if p999 > 10000:
        print(f'    [FAIL] 读挨饿严重! P99.9={p999:.0f}us > 10ms')
    elif p999 > 2000:
        print(f'    [WARN] 读延迟受写影响，P99.9={p999:.0f}us')
" 2>/dev/null || true
    fi
  done
done

echo ""
echo "--- 写挨饿测试 (Writer Starvation) ---"
echo "  原理: 大量读线程时，写请求的延迟变化"

for readers in 1 4 8; do
  for writers in 1 2; do
    echo "  R=${readers} W=${writers} ..."

    fio --filename="$EMMC_DEV" \
        --direct=1 \
        --rw=randread \
        --bs=4k \
        --size=$SIZE \
        --iodepth=8 \
        --numjobs=$readers \
        --ioengine=libaio \
        --group_reporting \
        --runtime=30 \
        --time_based \
        --name=starv_readbg_r${readers}_w${writers} \
        --output=/dev/null 2>/dev/null &

    READ_PID=$!
    BG_PIDS+=("$READ_PID")

    fio --filename="$EMMC_DEV" \
        --direct=1 \
        --rw=randwrite \
        --bs=4k \
        --size=$SIZE \
        --iodepth=1 \
        --numjobs=$writers \
        --ioengine=libaio \
        --group_reporting \
        --runtime=30 \
        --time_based \
        --name=starv_write_r${readers}_w${writers} \
        --output="${RESULT_DIR}/starvation_write_r${readers}_w${writers}.json" \
        --output-format=json \
        --lat_percentiles=1 2>/dev/null

    wait $READ_PID 2>/dev/null
  done
done

echo ""
echo "--- 死锁/挂起检测 ---"
echo "  原理: 创建大量并发线程做混合IO,检测是否有任务卡死"
echo "  设置60秒超时..."

timeout 70 fio --filename="$EMMC_DEV" \
    --direct=1 \
    --rw=randrw \
    --rwmixread=50 \
    --bs=4k \
    --size=$SIZE \
    --iodepth=32 \
    --numjobs=32 \
    --ioengine=libaio \
    --group_reporting \
    --runtime=60 \
    --time_based \
    --name=deadlock_test \
    --output="${RESULT_DIR}/deadlock_test.json" \
    --output-format=json 2>/dev/null

DEADLOCK_RC=$?
if [ $DEADLOCK_RC -eq 0 ]; then
  echo "  [PASS] 32线程并发混合IO无死锁"
else
  echo "  [FAIL] 32线程并发测试未正常完成(rc=$DEADLOCK_RC)，可能存在挂起!"
fi

RESULTS+=("$(parse_fio_result "${RESULT_DIR}/deadlock_test.json" "并发死锁检测")")

echo ""
echo "--- 优先级测试: 同步+直接IO混用 ---"
echo "  模拟实时任务(同步sync)和大块后台任务(直接IO)并发"

fio <<EOF 2>/dev/null &
[high_prio]
filename=$EMMC_DEV
direct=1
rw=randread
bs=4k
size=$SIZE
iodepth=1
numjobs=1
ioengine=sync
runtime=30
time_based
name=high_prio
write_lat_log=${LOG_DIR}/prio_high

[low_prio]
filename=$EMMC_DEV
direct=1
rw=write
bs=1m
size=$SIZE
iodepth=32
numjobs=4
ioengine=libaio
runtime=30
time_based
name=low_prio
EOF
FIO_PID=$!
wait $FIO_PID 2>/dev/null

echo ""
echo "====== 多线程竞态测试结果 ======"
for r in "${RESULTS[@]}"; do
  echo "  $r"
done

append_summary "多线程竞态" "$([ $DEADLOCK_RC -eq 0 ] && echo '无死锁' || echo '可能存在挂起')"
