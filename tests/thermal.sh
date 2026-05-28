#!/bin/bash
# ============================================================
# 热降频与老化模拟测试 (Thermal Throttle)
#
# 原理：eMMC 在温度过高时会触发热降频(throttling)，
#   写入速度会周期性下降。某些劣质 eMMC 的 throttling
#   策略过于激进，导致性能剧烈波动。
#
# 测试方法：
#   1. 长时间持续写入，监测性能波动
#   2. 检测周期性的降频模式（常见于热保护）
#   3. 检测降频恢复后的性能是否回到原始水平
#   4. 模拟"冷启动→预热→稳定"全过程
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "========================================"
echo "  热降频与老化模拟测试 (Thermal)"
echo "========================================"
reset_device

RESULTS=()
EMMC_TEMP_SUPPORT=0

# --- eMMC 内部温度读取（优先级1）---
get_emmc_temp() {
  # 方法1: mmc-utils EXT_CSD
  if command -v mmc &>/dev/null; then
    local raw=$(mmc extcsd read "$EMMC_DEV" 2>/dev/null | grep "^Extended CSD\[261\]" | awk '{print $NF}')
    if [ -n "$raw" ]; then
      # byte 261: bits[6:0] = temperature in °C
      local val=$((raw & 127))
      if [ "$val" -gt 0 ] && [ "$val" -lt 127 ]; then
        EMMC_TEMP_SUPPORT=1
        echo "$val"
        return
      fi
    fi
  fi

  # 方法2: debugfs ext_csd
  for dbg in /sys/kernel/debug/mmc*/mmc*/ext_csd; do
    [ -f "$dbg" ] || continue
    local raw=$(grep "EXT_CSD\[261\]" "$dbg" 2>/dev/null | awk '{print $NF}')
    if [ -n "$raw" ]; then
      local val=$((raw & 127))
      if [ "$val" -gt 0 ] && [ "$val" -lt 127 ]; then
        EMMC_TEMP_SUPPORT=1
        echo "$val"
        return
      fi
    fi
  done

  # 方法3: hwmon (部分eMMC控制器暴露为hwmon设备)
  for hwmon in /sys/class/hwmon/hwmon*/temp1_input; do
    [ -f "$hwmon" ] || continue
    local devpath=$(readlink -f "$hwmon" 2>/dev/null)
    if echo "$devpath" | grep -qi "mmc\|emm\|sdhci"; then
      local temp=$(cat "$hwmon" 2>/dev/null)
      [ -n "$temp" ] && echo "$((temp / 1000))" && EMMC_TEMP_SUPPORT=1 && return
    fi
  done

  echo ""
}

# --- SoC 温度读取（备选）---
get_soc_temp() {
  for path in /sys/class/thermal/thermal_zone*/temp; do
    [ -f "$path" ] || continue
    local name=$(cat "${path%/*}/type" 2>/dev/null)
    # 优先 soc_thermal / cpu_thermal
    if echo "$name" | grep -qi "soc\|cpu"; then
      echo $(($(cat "$path") / 1000))
      return
    fi
  done
  # 随便取一个
  for path in /sys/class/thermal/thermal_zone*/temp; do
    [ -f "$path" ] && echo $(($(cat "$path") / 1000)) && return
  done
  echo ""
}

# --- 统一温度采样 ---
sample_temp() {
  local label=$1
  local emmc_t=$(get_emmc_temp)
  local soc_t=$(get_soc_temp)
  if [ -n "$emmc_t" ]; then
    echo "$emmc_t"
  elif [ -n "$soc_t" ]; then
    echo "$soc_t"
  else
    echo "0"
  fi
}

# --- 温度来源说明 ---
temp_source_info() {
  get_emmc_temp > /dev/null
  if [ "$EMMC_TEMP_SUPPORT" -eq 1 ]; then
    echo "  eMMC内部温度传感器: 支持 (EXT_CSD[261])"
  else
    echo "  eMMC内部温度传感器: 不可用（eMMC未实现或缺少mmc-utils）"
    echo "  温度源: SoC thermal zone (非eMMC真实温度)"
  fi
}

echo ""
echo "--- 温度监测 ---"
temp_source_info
T0=$(sample_temp)
echo "  起始温度: ${T0}°C"

echo ""
echo "--- 持续写入温度压力 ---"
echo "  持续5分钟满负载写入，监测性能波动..."
echo "  同时每30秒记录一次 eMMC/SoC 温度..."

# 启动后台温度记录
rm -f "${LOG_DIR}/thermal_temp.log"
( for i in $(seq 0 5 300); do
    t=$(sample_temp)
    echo "$i $t" >> "${LOG_DIR}/thermal_temp.log"
    sleep 5
  done ) &
TEMP_MONITOR_PID=$!

fio --filename="$EMMC_DEV" \
    --direct=1 \
    --rw=write \
    --bs=1m \
    --size=100% \
    --iodepth=64 \
    --numjobs=2 \
    --ioengine=libaio \
    --group_reporting \
    --runtime=300 \
    --time_based \
    --ramp_time=10 \
    --name=thermal_write \
    --write_bw_log="${LOG_DIR}/thermal_bw" \
    --output="${RESULT_DIR}/thermal_write.json" \
    --output-format=json \
    --log_avg_msec=1000 2>/dev/null

wait $TEMP_MONITOR_PID 2>/dev/null

T1=$(sample_temp)
echo "  结束温度: ${T1}°C"
echo "  温升: $((T1 - T0))°C"

RESULTS+=("$(parse_fio_result "${RESULT_DIR}/thermal_write.json" "热负载写入")")

# --- 分析性能波动 ---
echo ""
echo "--- 热降频分析 ---"
if [ -f "${LOG_DIR}/thermal_bw.log" ]; then
  python3 -c "
import csv, statistics, math

bws = []
with open('${LOG_DIR}/thermal_bw.log') as f:
    for line in f:
        parts = line.strip().split(',')
        if len(parts) >= 2 and parts[1]:
            try:
                bws.append(int(parts[1]))
            except:
                pass

if bws:
    # 过滤掉前10个采样(ramp up)
    bws = bws[10:] if len(bws) > 10 else bws
    if not bws:
        print('  无有效数据')
        exit()

    avg = statistics.mean(bws)
    median = statistics.median(bws)
    min_bw = min(bws)
    max_bw = max(bws)
    stddev = statistics.stdev(bws) if len(bws) > 1 else 0
    cv = stddev / avg * 100 if avg > 0 else 0  # 变异系数

    print(f'  采样数: {len(bws)}')
    print(f'  平均带宽: {avg:.0f} KB/s')
    print(f'  中位数带宽: {median:.0f} KB/s')
    print(f'  最小带宽: {min_bw:.0f} KB/s')
    print(f'  最大带宽: {max_bw:.0f} KB/s')
    print(f'  标准差: {stddev:.0f}')
    print(f'  变异系数CV: {cv:.1f}%')

    # 检测降频事件: 持续带宽低于平均的70%
    threshold = avg * 0.7
    in_throttle = False
    throttle_events = []
    throttle_start = 0
    for i, bw in enumerate(bws):
        if bw < threshold and not in_throttle:
            throttle_start = i
            in_throttle = True
        elif bw >= threshold and in_throttle:
            throttle_events.append((throttle_start, i - throttle_start))
            in_throttle = False
    if in_throttle:
        throttle_events.append((throttle_start, len(bws) - throttle_start))

    if throttle_events:
        print(f'  降频事件数: {len(throttle_events)}')
        total_throttle = sum(d for _, d in throttle_events)
        print(f'  总降频时长: {total_throttle}秒')
        print(f'  降频占比: {total_throttle/len(bws)*100:.1f}%')
        if total_throttle / len(bws) > 0.3:
            print(f'  [FAIL] 热降频严重，超过30%时间在降频状态')
        elif total_throttle / len(bws) > 0.1:
            print(f'  [WARN] 存在热降频，{total_throttle/len(bws)*100:.0f}%时间受限')
        else:
            print(f'  [PASS] 热控制良好')
    else:
        print(f'  [PASS] 未检测到显著降频事件')

    # 周期性检测: 使用自相关检测周期性降频
    if len(bws) > 60:
        windows = [bws[i:i+30] for i in range(0, len(bws)-30, 15)]
        if windows:
            window_avgs = [statistics.mean(w) for w in windows]
            peaks = [i for i in range(1, len(window_avgs)-1) 
                    if window_avgs[i] < window_avgs[i-1]*0.8 and window_avgs[i] < window_avgs[i+1]*0.8]
            if len(peaks) >= 3:
                intervals = [peaks[i+1]-peaks[i] for i in range(len(peaks)-1)]
                avg_interval = statistics.mean(intervals) * 15
                print(f'  检测到周期性降频, 周期约{avg_interval:.0f}秒')
                print(f'  [WARN] eMMC存在周期性throttling行为')

    # --- 温度-性能关联分析 ---
    T0 = ${T0:-0}
    T1 = ${T1:-0}
    temp_rise = T1 - T0
    temp_src = 'eMMC内部' if ${EMMC_TEMP_SUPPORT:-0} else 'SoC(备选)'
    print(f'  温度: 起始={T0}°C → 终止={T1}°C (源: {temp_src})')
    if temp_rise > 30:
        print(f'  [WARN] 温升{temp_rise}°C, 散热可能不足')

    # 温度-带宽关联 (从thermal_temp.log读取)
    temp_bw = []
    try:
        with open('${LOG_DIR}/thermal_temp.log') as tf:
            for line in tf:
                parts = line.strip().split()
                if len(parts) >= 2:
                    t_sec = int(parts[0])
                    t_val = int(parts[1])
                    if t_val > 0 and t_sec < len(bws):
                        bw_at_t = bws[t_sec] if t_sec < len(bws) else 0
                        temp_bw.append((t_val, bw_at_t))
    except:
        pass

    if len(temp_bw) >= 5:
        temps = [t for t,_ in temp_bw]
        bws_corr = [b for _,b in temp_bw]
        # 温度上升 vs 带宽下降的趋势
        if max(temps) - min(temps) > 5:
            early_avg = statistics.mean(bws_corr[:len(bws_corr)//3])
            late_avg = statistics.mean(bws_corr[-len(bws_corr)//3:])
            bw_drop = (1 - late_avg/early_avg)*100 if early_avg > 0 else 0
            print(f'  温度变化: {min(temps)}°C → {max(temps)}°C')
            print(f'  带宽变化: {early_avg:.0f} → {late_avg:.0f} KB/s ({bw_drop:.1f}%)')
            if bw_drop > 50:
                print(f'  [FAIL] 高温度下性能衰减{bw_drop:.0f}%, 热降频显著')
            elif bw_drop > 20:
                print(f'  [WARN] 高温度下性能衰减{bw_drop:.0f}%, 可能有热影响')
" 2>/dev/null || true
fi

echo ""
echo "--- 冷却后性能恢复 ---"
echo "  等待 60秒 冷却..."
sleep 60

T2=$(sample_temp)
echo "  冷却后温度: ${T2}°C"

fio --filename="$EMMC_DEV" \
    --direct=1 \
    --rw=write \
    --bs=1m \
    --size=512M \
    --iodepth=32 \
    --ioengine=libaio \
    --name=thermal_recovery \
    --output="${RESULT_DIR}/thermal_recovery.json" \
    --output-format=json 2>/dev/null

REC_BW=$(python3 -c "
import json
d = json.load(open('${RESULT_DIR}/thermal_recovery.json'))
print(d.get('jobs',[{}])[0].get('write',{}).get('bw',0))
" 2>/dev/null)
echo "  恢复后带宽: ${REC_BW} KB/s"

RESULTS+=("$(parse_fio_result "${RESULT_DIR}/thermal_recovery.json" "热恢复")")

echo ""
echo "====== 热降频测试结果 ======"
append_summary "热降频" "温升: $((T1-T0))°C, 恢复BW: ${REC_BW}KB/s, 温度源: $([ "$EMMC_TEMP_SUPPORT" -eq 1 ] && echo "eMMC" || echo "SoC")"
