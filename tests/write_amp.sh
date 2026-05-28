#!/bin/bash
# ============================================================
# 写入放大估算测试 (Write Amplification)
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  写入放大估算测试 (Write Amplification)"
echo "========================================"
reset_device

RESULTS=()

echo ""
echo "--- eMMC 生命周期信息 ---"
get_mmc_write_cnt() {
  local ext_csd_paths=$(ls /sys/kernel/debug/mmc*/mmc*/ext_csd 2>/dev/null)
  for f in $ext_csd_paths; do
    [ -f "$f" ] || continue
    local user_est=$(grep -a "EXT_CSD\[268\]" "$f" 2>/dev/null | awk '{print $NF}')
    local slc_est=$(grep -a "EXT_CSD\[269\]" "$f" 2>/dev/null | awk '{print $NF}')
    local eol=$(grep -a "EXT_CSD\[267\]" "$f" 2>/dev/null | awk '{print $NF}')
    [ -n "$user_est" ] && echo "   用户区寿命: ${user_est}"
    [ -n "$slc_est" ] && echo "    SLC区寿命: ${slc_est}"
    [ -n "$eol" ] && echo "    Pre-EOL: ${eol}"
  done
}

get_mmc_write_cnt

echo ""
echo "--- IOPS 对比估算 ---"
echo "  顺序写(FTL开销最小)做基准, 其他模式IOPS比反映FTL开销"
SIZE="2G"

echo "  A) 4K顺序写 (基准, 放大≈1x)..."
fio --filename="$EMMC_DEV" \
    --direct=1 --rw=write --bs=4k --size=$SIZE --iodepth=32 \
    --ioengine=libaio --name=waf_seq_4k \
    --output="${RESULT_DIR}/waf_seq_4k.json" --output-format=json 2>/dev/null || true

echo "  B) 4K随机写 (GC触发, 放大升高)..."
fio --filename="$EMMC_DEV" \
    --direct=1 --rw=randwrite --bs=4k --size=$SIZE --iodepth=32 \
    --ioengine=libaio --name=waf_rand_4k \
    --output="${RESULT_DIR}/waf_rand_4k.json" --output-format=json 2>/dev/null || true

echo "  C) 512B随机写 (最高放大)..."
fio --filename="$EMMC_DEV" \
    --direct=1 --rw=randwrite --bs=512 --size=$SIZE --iodepth=32 \
    --ioengine=libaio --name=waf_rand_512 \
    --output="${RESULT_DIR}/waf_rand_512.json" --output-format=json 2>/dev/null || true

echo "  D) 4K随机混合 (模拟真实负载)..."
fio --filename="$EMMC_DEV" \
    --direct=1 --rw=randrw --rwmixread=50 --bs=4k --size=$SIZE --iodepth=16 \
    --ioengine=libaio --name=waf_mixed \
    --output="${RESULT_DIR}/waf_mixed.json" --output-format=json 2>/dev/null || true

echo ""
echo "--- 写放大因子推算 ---"
cat > "${LOG_DIR}/waf_analyze.py" << 'PYEOF'
import json, os, sys

rd = sys.argv[1]

def get_iops(name):
    path = os.path.join(rd, name)
    try:
        d = json.load(open(path))
        return d.get('jobs', [{}])[0].get('write', {}).get('iops', 0)
    except:
        return 0

seq_iops = get_iops("waf_seq_4k.json")
rand_iops = get_iops("waf_rand_4k.json")
rand512_iops = get_iops("waf_rand_512.json")
mixed_iops = get_iops("waf_mixed.json")

print(f'  {"写入模式":<20} {"IOPS":>8} {"相对FTL开销比":>14}')
print(f'  {"-"*44}')
print(f'  {"4K顺序写(基准)":<20} {seq_iops:>8} {"1.0x(基准)":>14}')

if seq_iops > 0:
    for name, iops in [("4K随机写", rand_iops), ("512B随机写", rand512_iops), ("4K随机混合", mixed_iops)]:
        ratio = seq_iops / iops if iops > 0 else 0
        label = f"{ratio:.1f}x"
        if ratio > 10:
            label += " 极高FTL开销"
        elif ratio > 5:
            label += " FTL开销偏高"
        elif ratio > 2:
            label += " FTL开销正常"
        else:
            label += " FTL开销优秀"
        print(f'  {name:<20} {iops:>8} {label:>20}')
else:
    print("  (基准数据缺失)")
PYEOF

python3 "${LOG_DIR}/waf_analyze.py" "$RESULT_DIR"
rm -f "${LOG_DIR}/waf_analyze.py"

echo ""
echo "--- 大规模写入后生命周期 ---"
fio --filename="$EMMC_DEV" \
    --direct=1 --rw=randwrite --bs=4k --size=5G --iodepth=32 \
    --ioengine=libaio --name=waf_big_write \
    --output=/dev/null 2>/dev/null || true

echo "  写入后 eMMC 状态:"
get_mmc_write_cnt

echo ""
echo "====== 写入放大测试结果 ======"
append_summary "写入放大(FTL开销)" \
  "4K顺序写IOPS vs 4K随机写IOPS比值估算FTL开销"
