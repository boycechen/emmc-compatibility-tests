#!/bin/bash
# ============================================================
# 测试结果分析工具
# 从已有结果中提取关键指标并生成报告
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  测试结果分析器"
echo "========================================"

if [ ! -d "$RESULT_DIR" ] || [ -z "$(ls -A "$RESULT_DIR" 2>/dev/null)" ]; then
  echo "[ERROR] 结果目录为空或不存在: $RESULT_DIR"
  exit 1
fi

echo ""
echo "--- 所有测试结果 ---"
for f in "$RESULT_DIR"/*.json; do
  [ -f "$f" ] || continue
  name=$(basename "$f" .json)
  parse_fio_result "$f" "$name"
done

echo ""
echo "--- 性能排序 ---"
python3 -c "
import json, glob, os

data = []
for f in glob.glob('${RESULT_DIR}/*.json'):
    name = os.path.basename(f).replace('.json', '')
    try:
        d = json.load(open(f))
        job = d.get('jobs', [{}])[0]
        for rw in ['read', 'write']:
            if job.get(rw):
                iops = job[rw].get('iops', 0)
                bw = job[rw].get('bw', 0)
                clat = job[rw].get('clat_ns', {}).get('percentile', {})
                p50 = clat.get('50.000000', 0) / 1000
                p99 = clat.get('99.000000', 0) / 1000
                data.append((name, rw, iops, bw, p50, p99))
    except:
        pass

if data:
    # 按 IOPS 降序
    sorted_data = sorted(data, key=lambda x: x[2], reverse=True)
    print(f'  {\"Test\":<40} {\"RW\":<6} {\"IOPS\":>10} {\"BW(KB/s)\":>12} {\"P50(us)\":>10} {\"P99(us)\":>10}')
    print(f'  {\"-\"*90}')
    for name, rw, iops, bw, p50, p99 in sorted_data[:20]:
        print(f'  {name:<40} {rw:<6} {iops:>10} {bw:>12} {p50:>10.1f} {p99:>10.1f}')
" 2>/dev/null || echo "  (解析失败，请确认结果文件格式)"

echo ""
echo "--- 报告生成 ---"
REPORT_FILE="${RESULT_DIR}/report_$(date +%Y%m%d_%H%M%S).md"
{
  echo "# eMMC 兼容性测试报告"
  echo ""
  echo "## 设备信息"
  echo '```'
  cat "${RESULT_DIR}/device_info.txt" 2>/dev/null || echo "(无设备信息)"
  echo '```'
  echo ""
  echo "## 测试结果摘要"
  echo '```'
  cat "${RESULT_DIR}/summary.txt" 2>/dev/null || echo "(无摘要)"
  echo '```'
  echo ""
  echo "## 性能数据"
  echo '```'
  for f in "$RESULT_DIR"/*.json; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .json)
    parse_fio_result "$f" "$name"
  done
  echo '```'
} > "$REPORT_FILE"

echo "  报告已生成: $REPORT_FILE"
