#!/bin/bash
echo "Monitoring dBrief Memory and CPU usage..."
echo "Press Ctrl+C to stop"
printf "TIME\t\tCPU%%\tMEM%%\tRAM (MB)\n"
while true; do
    TIME=$(date "+%H:%M:%S")
    # Get stats for dBrief
    STATS=$(ps -A -o %cpu,%mem,rss,comm | grep -v grep | grep MacOS/dBrief)
    if [ -n "$STATS" ]; then
        CPU=$(echo "$STATS" | awk '{print $1}')
        MEM=$(echo "$STATS" | awk '{print $2}')
        RSS_KB=$(echo "$STATS" | awk '{print $3}')
        RSS_MB=$(echo "scale=1; $RSS_KB / 1024" | bc)
        printf "%s\t%s%%\t%s%%\t%s MB\n" "$TIME" "$CPU" "$MEM" "$RSS_MB"
    else
        printf "%s\t--dBrief not running--\n" "$TIME"
    fi
    sleep 2
done
