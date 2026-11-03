#!/bin/sh
# lab_sarm.sh -- SIGSTOP-freeze + /dev/mem differential (S arm, lab lane 2026-11-01)
#
# Question: does the 32B record writer need a LIVE process / live va_list?
#   freeze N of M canaries (SIGSTOP), keep the rest running as activity control,
#   snapshot the frozen victims' write-target pages from /dev/mem, then diff every interval.
#
# usage: lab_sarm.sh start <tag> <ncanary> <nfreeze> <rounds> <interval_s>
#        lab_sarm.sh status <tag>
#        lab_sarm.sh stop <tag>
# outputs: /data/repro/exp/<tag>/{manifest.txt,pids.txt,frozen.txt,pa.txt,corr.tsv,rounds/,summary.txt,state}
# page read: dd if=/dev/mem bs=4096 skip=<pa/4096> count=1  (read-only)
EXP=/data/repro/exp
BIN=/data/repro/vsurv4

rpk() { awk -v n="$1" '{gsub(":"," ")} $1==n{print $3}' /proc/net/dev; }
h4c() { ls /data/repro/h4_"$1"_*.bin 2>/dev/null | wc -l; }
startstack() { cut -d" " -f28 /proc/$1/stat 2>/dev/null; }
patrace() {   # $1 pid, $2 hexva -> echo pa
  printf "$1 $2\n" > /proc/patrace
  sed -n 's/.*pa=0x\([0-9a-f]*\).*/\1/p' /proc/patrace
}
readpg() {    # $1 pa(hex) $2 outfile
  dd if=/dev/mem bs=4096 skip=$(( $1 / 4096 )) count=1 of=$2 2>/dev/null
  md5sum $2 | awk '{print $1}'
}
alive() { [ -r /proc/$1/exe ] && [ "$(readlink /proc/$1/exe)" = "$BIN" ] && echo 1 || echo 0; }

do_run() {
  TAG=$1; NC=$2; NF=$3; ROUNDS=$4; IVL=$5
  B=$EXP/$TAG
  mkdir -p $B/rounds
  : > $B/pids.txt; : > $B/frozen.txt; : > $B/pa.txt; : > $B/corr.tsv
  printf 'ts\tround\tphase\teth0_rxp\teth1_rxp\th4_total\th4_frozen\th4_control\n' > $B/corr.tsv
  i=0
  while [ $i -lt $NC ]; do
    taskset -c $(( 2 + (i % 2) )) $BIN >/dev/null 2>&1 &
    echo $! >> $B/pids.txt
    i=$((i + 1))
  done
  sleep 3
  # ---- phase 1: baseline activity (120 s) ----
  t=0
  while [ $t -lt 120 ]; do
    echo "$(date +$s)	-	base	$(rpk eth0)	$(rpk eth1)	$(ls /data/repro/h4_*.bin | wc -l)	-	-" >> $B/corr.tsv
    sleep 30; t=$((t + 30))
  done
  # ---- phase 2: freeze NF pids ----
  k=0
  for p in $(cat $B/pids.txt); do
    if [ $k -lt $NF ]; then kill -STOP $p; echo $p >> $B/frozen.txt; fi
    k=$((k + 1))
  done
  sleep 2
  # VA->PA for both candidate slots of every canary
  for p in $(cat $B/pids.txt); do
    ss=$(startstack $p)
    [ -z "$ss" ] && continue
    for off in 0x390 0x3a0; do
      va=$(( ss - off ))
      pa=$(patrace $p $(printf '0x%x' $va))
      echo "pid=$p off=$off va=$(printf '0x%x' $va) pa=0x$pa" >> $B/pa.txt
    done
  done
  # S0 snapshot: frozen pids, slots that resolved
  while read ln; do
    case "$ln" in pid=*) ;; *) continue;; esac
    p=$(echo $ln | sed -n 's/pid=\([0-9]*\).*/\1/p')
    off=$(echo $ln | sed -n 's/.*off=\(0x[0-9a-f]*\).*/\1/p')
    pa=$(echo $ln | sed -n 's/.*pa=0x\([0-9a-f]*\).*/\1/p')
    [ -z "$pa" ] && continue
    grep -q "^$p\$" $B/frozen.txt || continue
    readpg $pa $B/rounds/r00_$p_$off.bin >/dev/null
  done < $B/pa.txt
  # ---- phase 3: ROUNDS x interval sampling ----
  r=1
  while [ $r -le $ROUNDS ]; do
    fz=0
    for p in $(cat $B/frozen.txt); do fz=$(( fz + $(h4c $p) )); done
    tot=$(ls /data/repro/h4_*.bin | wc -l)
    while read ln; do
      case "$ln" in pid=*) ;; *) continue;; esac
      p=$(echo $ln | sed -n 's/pid=\([0-9]*\).*/\1/p')
      off=$(echo $ln | sed -n 's/.*off=\(0x[0-9a-f]*\).*/\1/p')
      pa=$(echo $ln | sed -n 's/.*pa=0x\([0-9a-f]*\).*/\1/p')
      [ -z "$pa" ] && continue
      grep -q "^$p\$" $B/frozen.txt || continue
      readpg $pa $B/rounds/r$(printf '%02d' $r)_$p_$off.bin >/dev/null
    done < $B/pa.txt
    echo "$(date +$s)	$r	frz	$(rpk eth0)	$(rpk eth1)	$tot	$fz	-	" >> $B/corr.tsv
    r=$((r + 1))
    sleep $IVL
  done
  # ---- phase 4: CONT then kill ----
  for p in $(cat $B/frozen.txt); do kill -CONT $p 2>/dev/null; done
  sleep 1
  for p in $(cat $B/pids.txt); do
    [ "$(readlink /proc/$p/exe 2>/dev/null)" = "$BIN" ] && kill -9 $p 2>/dev/null
  done
  {
    echo "tag=$TAG"
    echo "ncanary=$NC nfreeze=$NF rounds=$ROUNDS interval=$IVL"
    echo "start_epoch=$(cat $B/start_epoch.txt)"
    echo "end_epoch=$(date +$s)"
    echo "uptime=$(cat /proc/uptime)"
    echo "bootid=$(cat /proc/sys/kernel/random/boot_id)"
    echo "--- pa.txt ---"; cat $B/pa.txt
    echo "--- frozen ---"; cat $B/frozen.txt
    echo "--- round md5 (all pages) ---"
    md5sum $B/rounds/*.bin
  } > $B/summary.txt
  echo DONE > $B/state
}

CMD=$1; TAG=$2; B=$EXP/$TAG
case "$CMD" in
  start)
    NC=$3; NF=$4; ROUNDS=$5; IVL=$6
    mkdir -p $B
    if [ -f $B/state ] && grep -q RUNNING $B/state; then echo "REFUSED running"; exit 2; fi
    echo RUNNING > $B/state
    date +$s > $B/start_epoch.txt
    {
      echo "tag=$TAG ncanary=$NC nfreeze=$NF rounds=$ROUNDS interval=$IVL"
      echo "start_epoch=$(date +$s)"
      echo "uptime=$(cat /proc/uptime)"
      echo "bootid=$(cat /proc/sys/kernel/random/boot_id)"
      echo "kernel=$(uname -a)"
      echo "bin_md5=$(md5sum $BIN)"
      echo "lsmod=$(awk '{print $1}' /proc/modules | sort | tr '\n' ' ')"
    } > $B/manifest.txt
    nohup sh /data/repro/lab_sarm.sh _run "$TAG" "$NC" "$NF" "$ROUNDS" "$IVL" </dev/null >$B/supervise.log 2>&1 &
    echo $! > $B/supervisor.pid
    echo "STARTED tag=$TAG supervisor=$(cat $B/supervisor.pid)"
    ;;
  _run)
    do_run "$2" "$3" "$4" "$5" "$6"
    ;;
  status)
    echo "state=$(cat $B/state 2>/dev/null)"
    echo "pids=$(cat $B/pids.txt | tr '\n' ' ')"
    echo "frozen=$(cat $B/frozen.txt | tr '\n' ' ')"
    echo "corr_lines=$(wc -l < $B/corr.tsv)"
    echo "rounds_files=$(ls $B/rounds 2>/dev/null | wc -l)"
    tail -3 $B/corr.tsv
    ;;
  stop)
    [ -f $B/supervisor.pid ] && kill -9 $(cat $B/supervisor.pid) 2>/dev/null
    for p in $(cat $B/frozen.txt 2>/dev/null); do kill -CONT $p 2>/dev/null; done
    for p in $(cat $B/pids.txt 2>/dev/null); do
      [ "$(readlink /proc/$p/exe 2>/dev/null)" = "$BIN" ] && kill -9 $p 2>/dev/null
    done
    echo DONE > $B/state
    echo "STOPPED $TAG"
    ;;
  *) echo "usage: $0 start|status|stop <tag> ..."; exit 1;;
esac
