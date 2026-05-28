#!/bin/bash
# ============================================================
# SLC 缓存耗尽测试 (SLC Cache / pSLC Mode)
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  SLC 缓存耗尽测试 (SLC Cache)"
echo "========================================"
reset_device

DEV_SIZE=$(blockdev --getsize64 "$EMMC_DEV" 2>/dev/null)
if [ -z "$DEV_SIZE" ] || [ "$DEV_SIZE" -eq 0 ]; then
  echo "[ERROR] 无法获取设备大小"
  exit 1
fi
DEV_SIZE_MB=$((DEV_SIZE / 1048576))
DEV_SIZE_GB=$((DEV_SIZE_MB / 1024))
RESULTS=()

echo ""
echo "--- 连续写入逐步监测性能 ---"
echo "  设备容量: ${DEV_SIZE_GB}GB"
echo "  持续短时顺序写，分段记录速度..."

STEP_SIZE_MB=256
TOTAL_WRITTEN=0
MAX_WRITE_MB=$((DEV_SIZE_MB * 25 / 100))
STEPS=$((MAX_WRITE_MB / STEP_SIZE_MB))
BW_LOG="${LOG_DIR}/slc_bw.log"
: > "$BW_LOG"

for i in $(seq 1 $STEPS); do
  bw=$(fio --filename="$EMMC_DEV" \
      --direct=1 \
      --rw=write \
      --bs=1m \
      --size=${STEP_SIZE_MB}M \
      --offset=$((TOTAL_WRITTEN * 1048576)) \
      --iodepth=16 \
      --ioengine=libaio \
      --name=slc_step_${i} \
      --output-format=json 2>/dev/null | \
      python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('jobs',[{}])[0].get('write',{}).get('bw','0'))" 2>/dev/null || echo "0")

  TOTAL_WRITTEN=$((TOTAL_WRITTEN + STEP_SIZE_MB))
  TOTAL_MB=$((i * STEP_SIZE_MB))
  echo -n "  ${TOTAL_MB}MB: ${bw}KB/s"
  echo "$TOTAL_MB $bw" >> "$BW_LOG"
  echo ""
done

echo ""
echo "--- SLC 缓存性能分析 ---"
# 写临时 Python 脚本避免内联引用问题
PY_SCRIPT="${LOG_DIR}/slc_analyze.py"
cat > "$PY_SCRIPT" << 'PYEOF'
import statistics, sys

bws = []; steps = []
with open(sys.argv[1]) as f:
    for line in f:
        parts = line.strip().split()
        if len(parts) >= 2 and parts[1].isdigit():
            steps.append(int(parts[0]))
            bws.append(int(parts[1]))

if not bws:
    print("0 0", file=sys.stderr)
    sys.exit(1)

peak = max(bws)
threshold = peak * 0.5
cliff = 0
for i, b in enumerate(bws):
    if b < threshold and i > 0:
        cliff = steps[i]
        break

print(f"{peak} {cliff}")
PYEOF

analysis=$(python3 "$PY_SCRIPT" "$BW_LOG" 2>/dev/null || echo "0 0")
PEAK_BW=$(echo "$analysis" | awk '{print $1}')
CLIFF_MB=$(echo "$analysis" | awk '{print $2}')
rm -f "$PY_SCRIPT"

# 输出可读分析
python3 << PYEOF
bws = []; steps = []
with open("$BW_LOG") as f:
    for line in f:
        parts = line.strip().split()
        if len(parts) >= 2 and parts[1].isdigit():
            steps.append(int(parts[0]))
            bws.append(int(parts[1]))
if not bws:
    exit()
peak = max(bws)
threshold = peak * 0.5
cliff_at = -1
for i, b in enumerate(bws):
    if b < threshold and i > 0:
        cliff_at = i
        break
print(f"  采样点数: {len(bws)}")
print(f"  峰值带宽: {peak} KB/s (SLC缓存区)")
if cliff_at > 0:
    print(f"  性能拐点: ~{steps[cliff_at]}MB (带宽降至{bws[cliff_at]}KB/s)")
    print(f"  估计SLC缓存大小: ~{steps[cliff_at]}MB")
    tlc_bws = bws[cliff_at:]
    if tlc_bws:
        tlc_avg = sum(tlc_bws)/len(tlc_bws)
        ratio = peak/tlc_avg
        print(f"  TLC直写平均: {tlc_avg:.0f} KB/s")
        print(f"  SLC/TLC速度比: {ratio:.1f}x")
else:
    stable = sum(bws[min(3,len(bws)):])/max(1,len(bws)-3)
    print(f"  未检测到明显性能拐点")
    print(f"  稳定带宽: {stable:.0f} KB/s")
PYEOF

echo ""
echo "--- 缓存回收测试 ---"
echo "  写满SLC后，等待30s让控制器做GC回收..."
sleep 30

echo "  再次写入测试缓存恢复..."
fio --filename="$EMMC_DEV" \
    --direct=1 \
    --rw=write \
    --bs=1m \
    --size=512M \
    --offset=0 \
    --iodepth=16 \
    --ioengine=libaio \
    --name=slc_recovery \
    --output="${RESULT_DIR}/slc_recovery.json" \
    --output-format=json 2>/dev/null

RECOVERY_BW=$(python3 -c "
import json
d = json.load(open('${RESULT_DIR}/slc_recovery.json'))
print(d.get('jobs',[{}])[0].get('write',{}).get('bw',0))
" 2>/dev/null)
echo "  恢复后写带宽: ${RECOVERY_BW} KB/s"

RESULTS+=("$(parse_fio_result "${RESULT_DIR}/slc_recovery.json" "SLC回收恢复")")

echo ""
echo "====== SLC 缓存测试结果 ======"
append_summary "SLC缓存" "峰值BW: ${PEAK_BW:-N/A}KB/s, 拐点: ${CLIFF_MB:-N/A}MB, 恢复BW: ${RECOVERY_BW:-N/A}KB/s"
