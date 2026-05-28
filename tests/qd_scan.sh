#!/bin/bash
# ============================================================
# 测试项：队列深度扫描 (Queue Depth Scan)
# 场景：遍历不同队列深度，评估并发能力
# 关注指标：各 QD 下的 IOPS 和延迟
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  队列深度扫描 (Queue Depth Scan)"
echo "========================================"
reset_device

SIZE="1G"
BS="4k"
QUEUE_DEPTHS=(1 2 4 8 16 32 64 128)
NUMJOBS=(1 2 4 8)
RESULTS=()

echo ""
echo "--- 单 Job 变队列深度 ---"
for qd in "${QUEUE_DEPTHS[@]}"; do
  echo "  QD=${qd} 随机读..."
  fio --filename="$EMMC_DEV" \
      --direct=1 \
      --rw=randread \
      --bs=$BS \
      --size=$SIZE \
      --iodepth=$qd \
      --numjobs=1 \
      --ioengine=libaio \
      --runtime=20 \
      --time_based \
      --ramp_time=5 \
      --name=qdscan_read_qd${qd} \
      --output="${RESULT_DIR}/qdscan_read_qd${qd}.json" \
      --output-format=json 2>/dev/null

  echo "  QD=${qd} 随机写..."
  fio --filename="$EMMC_DEV" \
      --direct=1 \
      --rw=randwrite \
      --bs=$BS \
      --size=$SIZE \
      --iodepth=$qd \
      --numjobs=1 \
      --ioengine=libaio \
      --runtime=20 \
      --time_based \
      --ramp_time=5 \
      --name=qdscan_write_qd${qd} \
      --output="${RESULT_DIR}/qdscan_write_qd${qd}.json" \
      --output-format=json 2>/dev/null
done

echo ""
echo "--- 多 Job 并发 (QD=4) ---"
for nj in "${NUMJOBS[@]}"; do
  echo "  jobs=${nj} 随机读..."
  fio --filename="$EMMC_DEV" \
      --direct=1 \
      --rw=randread \
      --bs=$BS \
      --size=$SIZE \
      --iodepth=4 \
      --numjobs=$nj \
      --ioengine=libaio \
      --group_reporting \
      --runtime=20 \
      --time_based \
      --ramp_time=5 \
      --name=qdscan_rr_jobs${nj} \
      --output="${RESULT_DIR}/qdscan_read_jobs${nj}.json" \
      --output-format=json 2>/dev/null

  echo "  jobs=${nj} 随机写..."
  fio --filename="$EMMC_DEV" \
      --direct=1 \
      --rw=randwrite \
      --bs=$BS \
      --size=$SIZE \
      --iodepth=4 \
      --numjobs=$nj \
      --ioengine=libaio \
      --group_reporting \
      --runtime=20 \
      --time_based \
      --ramp_time=5 \
      --name=qdscan_rw_jobs${nj} \
      --output="${RESULT_DIR}/qdscan_write_jobs${nj}.json" \
      --output-format=json 2>/dev/null
done

echo ""
echo "====== 队列深度扫描结果 ======"
python3 -c "
import json, glob, os

def report(pattern, title):
    print(f'\n--- {title} ---')
    rows = []
    for f in sorted(glob.glob(pattern)):
        key = os.path.basename(f).replace('.json','')
        try:
            d = json.load(open(f))
            job = d.get('jobs',[{}])[0]
            for rw in ['read', 'write']:
                if job.get(rw):
                    iops = job[rw].get('iops', 0)
                    lat = job[rw].get('clat_ns',{}).get('percentile',{}).get('50.000000', 0) / 1000
                    rows.append((key, iops, lat))
        except:
            pass
    if rows:
        print(f'  {\"Key\":>20} {\"IOPS\":>10} {\"P50lat(us)\":>12}')
        print(f'  {\"-\"*44}')
        for key, iops, lat in rows:
            print(f'  {key:>20} {iops:>10} {lat:>12.1f}')

report('${RESULT_DIR}/qdscan_read_qd*.json', '随机读 - 变队列深度')
report('${RESULT_DIR}/qdscan_write_qd*.json', '随机写 - 变队列深度')
report('${RESULT_DIR}/qdscan_read_jobs*.json', '随机读 - 变并发数')
report('${RESULT_DIR}/qdscan_write_jobs*.json', '随机写 - 变并发数')
"
