#!/bin/bash
# ============================================================
# 测试项：块大小扫描 (Block Size Scan)
# 场景：遍历不同块大小，找出最优 IO 尺寸
# 关注指标：各 block size 下的带宽和 IOPS
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  块大小扫描 (Block Size Scan)"
echo "========================================"
reset_device

SIZE="1G"
BLOCK_SIZES=("512" "1k" "2k" "4k" "8k" "16k" "32k" "64k" "128k" "256k" "512k" "1m" "2m" "4m" "8m")
RESULTS=()

echo ""
echo "--- 顺序读块大小扫描 ---"
for bs in "${BLOCK_SIZES[@]}"; do
  output="${RESULT_DIR}/bsscan_seqread_${bs}.json"
  echo "  bs=${bs} ..."
  fio --filename="$EMMC_DEV" \
      --direct=1 \
      --rw=read \
      --bs=$bs \
      --size=$SIZE \
      --iodepth=32 \
      --numjobs=1 \
      --ioengine=libaio \
      --runtime=20 \
      --time_based \
      --ramp_time=3 \
      --name=bsscan_seqread_${bs} \
      --output="$output" \
      --output-format=json 2>/dev/null
done

echo ""
echo "--- 顺序写块大小扫描 ---"
for bs in "${BLOCK_SIZES[@]}"; do
  output="${RESULT_DIR}/bsscan_seqwrite_${bs}.json"
  echo "  bs=${bs} ..."
  fio --filename="$EMMC_DEV" \
      --direct=1 \
      --rw=write \
      --bs=$bs \
      --size=$SIZE \
      --iodepth=32 \
      --numjobs=1 \
      --ioengine=libaio \
      --runtime=20 \
      --time_based \
      --ramp_time=3 \
      --name=bsscan_seqwrite_${bs} \
      --output="$output" \
      --output-format=json 2>/dev/null
done

echo ""
echo "--- 随机读块大小扫描 ---"
for bs in "${BLOCK_SIZES[@]}"; do
  output="${RESULT_DIR}/bsscan_randread_${bs}.json"
  echo "  bs=${bs} ..."
  fio --filename="$EMMC_DEV" \
      --direct=1 \
      --rw=randread \
      --bs=$bs \
      --size=$SIZE \
      --iodepth=4 \
      --numjobs=1 \
      --ioengine=libaio \
      --runtime=20 \
      --time_based \
      --ramp_time=3 \
      --name=bsscan_randread_${bs} \
      --output="$output" \
      --output-format=json 2>/dev/null
done

echo ""
echo "====== 块大小扫描结果汇总 ======"
python3 -c "
import json, glob, os

def report(pattern, title):
    print(f'\n--- {title} ---')
    rows = []
    for f in sorted(glob.glob(pattern)):
        bs = os.path.basename(f).split('_')[-1].replace('.json','')
        try:
            d = json.load(open(f))
            job = d.get('jobs',[{}])[0]
            for rw in ['read', 'write']:
                if job.get(rw):
                    bw = job[rw].get('bw', 0)
                    iops = job[rw].get('iops', 0)
                    rows.append((bs, bw, iops))
        except:
            pass
    if rows:
        print(f'  {\"BS\":>8} {\"BW(KB/s)\":>12} {\"IOPS\":>8}')
        print(f'  {\"-\"*30}')
        for bs, bw, iops in rows:
            print(f'  {bs:>8} {bw:>12} {iops:>8}')
        # 找到最优
        best = max(rows, key=lambda x: x[1])
        print(f'  [最优块大小] {best[0]} (BW={best[1]}KB/s)')

report('${RESULT_DIR}/bsscan_seqread_*.json', '顺序读')
report('${RESULT_DIR}/bsscan_seqwrite_*.json', '顺序写')
report('${RESULT_DIR}/bsscan_randread_*.json', '随机读')
"
