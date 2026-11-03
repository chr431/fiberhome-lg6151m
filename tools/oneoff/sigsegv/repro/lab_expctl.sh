#!/bin/sh
# lab_expctl.sh -- autonomous experiment runner for the 32B-record hunt (lab lane, 2026-11-01)
#
# Why: every arm must survive SSH disconnect, leave a manifest, and normalise by
#      canary CPU-seconds.  One process tree: canaries -> stage driver + sampler -> summary.
#
# usage:
#   lab_expctl.sh start <tag> <bin> <ncanary> <planfile> [hitglob] [note]
#   lab_expctl.sh status <tag>
#   lab_expctl.sh stop   <tag>
#   lab_expctl.sh _run   <tag> <bin> <ncanary> <planfile> <hitglob> <note>   (internal)
#
# planfile: one stage per line, "<stage_name> <duration_s>"; '#' comments ignored.
# outputs : /data/repro/exp/<tag>/{manifest.txt,corr.tsv,stages.tsv,pids.txt,summary.txt,state,supervise.log}
# hitglob : default /data/repro/h4_*.bin (vsurv4); set to the scanary output glob when applicable.

EXP=/data/repro/exp
SLEEP_STEP=10

hits() { ls $1 2>/dev/null | wc -l; }
rxp()  { awk -v n="$1" '{gsub(":"," ")} $1==n{print $3}' /proc/net/dev; }
txp()  { awk -v n="$1" '{gsub(":"," ")} $1==n{print $11}' /proc/net/dev; }

cpu_ticks() {   # sum of utime+stime over pids listed in $1 (skips dead)
  tot=0
  for p in $(cat "$1" 2>/dev/null); do
    [ -r /proc/$p/stat ] || continue
    t=$(awk '{print $14+$15}' /proc/$p/stat 2>/dev/null)
    [ -n "$t" ] && tot=$((tot + t))
  done
  echo $tot
}

alive_n() {     # count pids from $1 still alive AND still running the expected binary
  n=0
  for p in $(cat "$1" 2>/dev/null); do
    [ -r /proc/$p/exe ] || continue
    e=$(readlink /proc/$p/exe 2>/dev/null)
    [ "$e" = "$2" ] && n=$((n + 1))
  done
  echo $n
}

kill_pids() {   # $1 = pids file, $2 = expected binary path (token-exact, NOT pgrep)
  for p in $(cat "$1" 2>/dev/null); do
    [ -r /proc/$p/exe ] || continue
    e=$(readlink /proc/$p/exe 2>/dev/null)
    if [ "$e" = "$2" ]; then kill -9 $p 2>/dev/null; fi
  done
}

sample() {      # $1=tag
  B=$EXP/$1
  ts=$(date +%s)
  up=$(cut -d. -f1 /proc/uptime)
  h=$(hits "$(cat $B/hitglob.txt)")
  c=$(cpu_ticks $B/pids.txt)
  n=$(alive_n $B/pids.txt "$(cat $B/binpath.txt)")
  ld=$(cut -d' ' -f1 /proc/loadavg)
  ma=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
  ct=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$ts" "$up" "$h" "$n" "$c" "$(rxp eth0)" "$(rxp eth1)" "$(rxp br-lan)" "$(rxp rai0)" "$(rxp ccmni2)" "$(txp eth0)" "$ld" "$ma" "$ct" >> $B/corr.tsv
}

do_stop() {     # $1=tag
  B=$EXP/$1
  kill_pids $B/pids.txt "$(cat $B/binpath.txt 2>/dev/null)"
  echo "$(date +%s) STOP" >> $B/stages.tsv
  echo DONE > $B/state
}

do_summary() {  # $1=tag
  B=$EXP/$1
  end=$(date +%s)
  start=$(cat $B/start_epoch.txt 2>/dev/null)
  h0=$(cat $B/h4_base.txt 2>/dev/null); h1=$(hits "$(cat $B/hitglob.txt)")
  c0=$(cat $B/cpu_base.txt 2>/dev/null); c1=$(cpu_ticks $B/pids.txt)
  printf 'tag=%s\nstart_epoch=%s\nend_epoch=%s\nduration_s=%s\n' "$1" "$start" "$end" "$((end - start))" > $B/summary.txt
  printf 'h4_base=%s\nh4_end=%s\nh4_delta=%s\n' "$h0" "$h1" "$((h1 - h0))" >> $B/summary.txt
  printf 'canary_cpu_ticks_base=%s\ncanary_cpu_ticks_end=%s\ncanary_cpu_ticks_delta=%s\n' "$c0" "$c1" "$((c1 - c0))" >> $B/summary.txt
  printf 'canary_cpu_sec_delta=%s\n' "$(( (c1 - c0) / 100 ))" >> $B/summary.txt
  printf 'uptime_end=%s\nbootid=%s\n' "$(cut -d. -f1 /proc/uptime)" "$(cat /proc/sys/kernel/random/boot_id)" >> $B/summary.txt
  echo "--- per-pid hits ---" >> $B/summary.txt
  for p in $(cat $B/pids.txt); do
    cnt=$(ls /data/repro/h4_"$p"_*.bin 2>/dev/null | wc -l)
    echo "pid=$p h4_files=$cnt" >> $B/summary.txt
  done
  echo "--- iface rx pkts at end (eth0 eth1 br-lan rai0 ccmni2) ---" >> $B/summary.txt
  echo "$(rxp eth0) $(rxp eth1) $(rxp br-lan) $(rxp rai0) $(rxp ccmni2)" >> $B/summary.txt
  echo "--- lsmod diff (start vs end) ---" >> $B/summary.txt
  awk '{print $1}' /proc/modules | sort > $B/lsmod_end.txt
  diff $B/lsmod_start.txt $B/lsmod_end.txt >> $B/summary.txt 2>&1
  echo "--- stages ---" >> $B/summary.txt
  cat $B/stages.tsv >> $B/summary.txt
}

do_run() {      # $1=tag $2=bin $3=ncanary $4=plan $5=hitglob $6=note
  TAG=$1; BIN=$2; NC=$3; PLAN=$4; GLOB=$5; NOTE=$6
  B=$EXP/$TAG
  echo "$BIN" > $B/binpath.txt
  echo "$GLOB" > $B/hitglob.txt
  : > $B/pids.txt
  i=0
  while [ $i -lt $NC ]; do
    c=$(( 2 + (i % 2) ))
    taskset -c $c $BIN >/dev/null 2>&1 &
    echo $! >> $B/pids.txt
    i=$((i + 1))
  done
  sleep 3
  echo "$(hits "$GLOB")" > $B/h4_base.txt
  echo "$(cpu_ticks $B/pids.txt)" > $B/cpu_base.txt
  while read stage dur; do
    case "$stage" in ''|\#*) continue;; esac
    s0=$(date +%s); h0=$(hits "$GLOB")
    echo "$s0 $stage START h4=$h0" >> $B/stages.tsv
    i=0
    while [ $i -lt $dur ]; do
      sample $TAG
      sleep $SLEEP_STEP
      i=$((i + SLEEP_STEP))
    done
    s1=$(date +%s); h1=$(hits "$GLOB")
    echo "$s1 $stage END h4=$h1 delta=$((h1 - h0)) dur=$((s1 - s0))" >> $B/stages.tsv
  done < $PLAN
  do_stop $TAG
  do_summary $TAG
}

CMD=$1; TAG=$2
B=$EXP/$TAG
case "$CMD" in
  start)
    BIN=$3; NC=$4; PLAN=$5
    if [ -n "$6" ]; then GLOB=$6; else GLOB=/data/repro/h4_*.bin; fi
    NOTE=$7
    mkdir -p $B
    if [ -f $B/state ] && grep -q RUNNING $B/state; then
      echo "REFUSED: tag $TAG already RUNNING"; exit 2
    fi
    echo RUNNING > $B/state
    date +%s > $B/start_epoch.txt
    printf 'ts\tup\th4\tncanary_alive\tcpu_ticks\teth0_rxp\teth1_rxp\tbrlan_rxp\trai0_rxp\tccmni2_rxp\teth0_txp\tload1\tmemavail_kb\tconntrack\n' > $B/corr.tsv
    : > $B/stages.tsv
    {
      echo "tag=$TAG"
      echo "note=$NOTE"
      echo "bin=$BIN"
      echo "ncanary=$NC"
      echo "plan=$PLAN"
      echo "hitglob=$GLOB"
      echo "start_epoch=$(date +%s)"
      echo "start_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      echo "uptime=$(cat /proc/uptime)"
      echo "bootid=$(cat /proc/sys/kernel/random/boot_id)"
      echo "kernel=$(uname -a)"
      echo "h4_base=$(hits "$GLOB")"
      echo "--- lsmod ---"
      awk '{print $1}' /proc/modules | sort
      echo "--- plan ---"
      cat $PLAN
      echo "--- bin md5 ---"
      md5sum $BIN
    } > $B/manifest.txt
    awk '{print $1}' /proc/modules | sort > $B/lsmod_start.txt
    nohup sh /data/repro/lab_expctl.sh _run "$TAG" "$BIN" "$NC" "$PLAN" "$GLOB" "$NOTE" </dev/null >$B/supervise.log 2>&1 &
    echo $! > $B/supervisor.pid
    echo "STARTED tag=$TAG supervisor=$(cat $B/supervisor.pid) plan=$PLAN"
    ;;
  _run)
    do_run "$2" "$3" "$4" "$5" "$6" "$7"
    ;;
  stop)
    if [ ! -d $B ]; then echo "NO_SUCH_TAG $TAG"; exit 2; fi
    [ -f $B/supervisor.pid ] && kill -9 $(cat $B/supervisor.pid) 2>/dev/null
    do_stop $TAG
    echo STOPPED tag=$TAG
    ;;
  status)
    if [ ! -d $B ]; then echo "NO_SUCH_TAG $TAG"; exit 2; fi
    echo "state=$(cat $B/state 2>/dev/null)"
    echo "pids=$(cat $B/pids.txt | tr '\n' ' ')"
    echo "alive=$(alive_n $B/pids.txt "$(cat $B/binpath.txt)")"
    echo "h4_now=$(hits "$(cat $B/hitglob.txt)")"
    echo "corr_lines=$(wc -l < $B/corr.tsv)"
    echo "--- stages ---"; cat $B/stages.tsv
    ;;
  *)
    echo "usage: $0 start|stop|status <tag> ..."; exit 1;;
esac
