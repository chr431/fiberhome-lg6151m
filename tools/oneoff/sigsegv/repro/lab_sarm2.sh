#!/bin/sh
# lab_sarm2.sh -- S arm v2: SIGSTOP-freeze + /dev/mem differential (lab lane, 2026-11-01)
# Gates (skeptic): G1 State:T + utime/stime unchanged; G2 no mlock / no /proc/pid/mem;
# G3 PA re-resolved every round (PA change => round invalid); G4 S0 = two back-to-back reads 0-byte diff;
# G5 /dev/mem readable positive control before freezing.
# usage: lab_sarm2.sh start <tag> <ncanary> <nfreeze> <rounds> <interval_s>
EXP=/data/repro/exp
BIN=/data/repro/vsurv4
rpk() { awk -v n="$1" '{gsub(":"," ")} $1==n{print $3}' /proc/net/dev; }
h4c() { ls /data/repro/h4_"$1"_*.bin 2>/dev/null | wc -l; }
cput() { awk '{print $14+$15}' /proc/"$1"/stat 2>/dev/null; }
pstate() { awk '{print $3}' /proc/"$1"/stat 2>/dev/null; }
ss_of() { cut -d" " -f28 /proc/"$1"/stat 2>/dev/null; }
pa_of() { printf "%s %s\n" "$1" "$2" > /proc/patrace; sed -n 's/.*pa=0x\([0-9a-f]*\).*/\1/p' /proc/patrace; }
readpg() { dd if=/dev/mem bs=4096 skip=$(( $1 / 4096 )) count=1 of="$2" 2>/dev/null; }
md5of() { md5sum "$1" | awk '{print $1}'; }
isbin() { [ -r /proc/"$1"/exe ] && [ "$(readlink /proc/"$1"/exe)" = "$BIN" ] && echo 1 || echo 0; }

do_run() {
  TAG=$1; NC=$2; NF=$3; ROUNDS=$4; IVL=$5
  B=$EXP/$TAG
  mkdir -p $B/rounds
  : > $B/pids.txt; : > $B/frozen.txt; : > $B/pa.txt
  printf 'ts\tphase\tround\teth0_rxp\teth1_rxp\th4_control\th4_frozen\tfrozen_state\tfrozen_cpu\n' > $B/corr.tsv
  i=0
  while [ $i -lt $NC ]; do
    taskset -c $(( 2 + (i % 2) )) $BIN >/dev/null 2>&1 &
    echo $! >> $B/pids.txt
    i=$((i + 1))
  done
  sleep 3
  p1=$(sed -n 1p $B/pids.txt); ss=$(ss_of $p1)
  ctlpa=$(pa_of $p1 $(printf '0x%x' $(( ss - 0x390 ))))
  readpg $ctlpa $B/ctl_page.bin
  ctlsum=$(md5of $B/ctl_page.bin); ctlzero=$(tr -d '\000' < $B/ctl_page.bin | wc -c)
  echo "poscontrol pid=$p1 pa=0x$ctlpa md5=$ctlsum nonzero_bytes=$ctlzero" >> $B/pa.txt
  t=0
  while [ $t -lt 120 ]; do
    echo "$(date +%s)	base	-	$(rpk eth0)	$(rpk eth1)	$(ls /data/repro/h4_*.bin | wc -l)	-	-	-" >> $B/corr.tsv
    sleep 30; t=$((t + 30))
  done
  k=0
  for p in $(cat $B/pids.txt); do
    if [ $k -lt $NF ]; then kill -STOP $p; echo $p >> $B/frozen.txt; fi
    k=$((k + 1))
  done
  sleep 2
  for p in $(cat $B/frozen.txt); do
    st1=$(pstate $p); c1=$(cput $p); sleep 2; st2=$(pstate $p); c2=$(cput $p)
    ok=0; [ "$st1" = "T" ] && [ "$st2" = "T" ] && [ "$c1" = "$c2" ] && ok=1
    echo "freeze_gate pid=$p state1=$st1 state2=$st2 cpu1=$c1 cpu2=$c2 ok=$ok" >> $B/pa.txt
  done
  for p in $(cat $B/frozen.txt); do
    ss=$(ss_of $p)
    for off in 0x390 0x3a0; do
      va=$(( ss - off )); vahex=$(printf '0x%x' $va)
      pa=$(pa_of $p $vahex)
      echo "pid=$p off=$off va=$vahex pa=0x$pa" >> $B/pa.txt
      [ -z "$pa" ] && continue
      fa=$B/rounds/r00_"$p"_"$off"_a.bin; fb=$B/rounds/r00_"$p"_"$off"_b.bin
      readpg $pa $fa; readpg $pa $fb
      sa=$(md5of $fa); sb=$(md5of $fb)
      echo "s0_gate pid=$p off=$off md5a=$sa md5b=$sb same=$([ "$sa" = "$sb" ] && echo 1 || echo 0)" >> $B/pa.txt
      if [ "$sa" = "$sb" ]; then mv $fa $B/rounds/r00_"$p"_"$off".bin; else echo "s0_unstable pid=$p off=$off" >> $B/pa.txt; fi
      rm -f $fb
    done
  done
  r=1
  while [ $r -le $ROUNDS ]; do
    while read ln; do
      case "$ln" in pid=*) ;; *) continue;; esac
      p=$(echo $ln | sed -n 's/pid=\([0-9]*\).*/\1/p')
      off=$(echo $ln | sed -n 's/.*off=\(0x[0-9a-f]*\).*/\1/p')
      pa0=$(echo $ln | sed -n 's/.*pa=0x\([0-9a-f]*\).*/\1/p')
      ss=$(ss_of $p); [ -z "$ss" ] && continue
      case $off in 0x390) va=$(( ss - 0x390 ));; *) va=$(( ss - 0x3a0 ));; esac
      pa=$(pa_of $p $(printf '0x%x' $va))
      if [ "$pa" != "$pa0" ]; then
        echo "round=$r pid=$p off=$off PA_MOVED 0x$pa0 -> 0x$pa (round invalid)" >> $B/pa.txt
        continue
      fi
      readpg $pa $B/rounds/r$(printf '%02d' $r)_"$p"_"$off".bin
    done < $B/pa.txt
    fz=0; for p in $(cat $B/frozen.txt); do fz=$(( fz + $(h4c $p) )); done
    ctl=0; for p in $(cat $B/pids.txt); do grep -qx $p $B/frozen.txt || ctl=$(( ctl + $(h4c $p) )); done
    stt=""; cpu=""; for p in $(cat $B/frozen.txt); do stt="$stt$(pstate $p)"; cpu="$cpu$(cput $p),"; done
    echo "$(date +%s)	frz	r$r	$(rpk eth0)	$(rpk eth1)	$ctl	$fz	$stt	$cpu" >> $B/corr.tsv
    r=$((r + 1)); sleep $IVL
  done
  for p in $(cat $B/frozen.txt); do kill -CONT $p 2>/dev/null; done
  sleep 1
  for p in $(cat $B/pids.txt); do [ "$(isbin $p)" = "1" ] && kill -9 $p 2>/dev/null; done
  { echo "tag=$TAG ncanary=$NC nfreeze=$NF rounds=$ROUNDS interval=$IVL"
    echo "start_epoch=$(cat $B/start_epoch.txt)"; echo "end_epoch=$(date +%s)"
    echo "uptime=$(cat /proc/uptime)"; echo "bootid=$(cat /proc/sys/kernel/random/boot_id)"
    echo "--- pa/gates ---"; cat $B/pa.txt
    echo "--- frozen ---"; cat $B/frozen.txt
    echo "--- md5 ---"; md5sum $B/rounds/*.bin
  } > $B/summary.txt
  echo DONE > $B/state
}

CMD=$1; TAG=$2; B=$EXP/$TAG
case "$CMD" in
  start)
    NC=$3; NF=$4; ROUNDS=$5; IVL=$6
    mkdir -p $B
    if [ -f $B/state ] && grep -q RUNNING $B/state; then echo "REFUSED running"; exit 2; fi
    echo RUNNING > $B/state; date +%s > $B/start_epoch.txt
    { echo "tag=$TAG ncanary=$NC nfreeze=$NF rounds=$ROUNDS interval=$IVL"
      echo "start_epoch=$(date +%s)"; echo "uptime=$(cat /proc/uptime)"
      echo "bootid=$(cat /proc/sys/kernel/random/boot_id)"; echo "kernel=$(uname -a)"
      echo "bin_md5=$(md5sum $BIN)"; echo "lsmod=$(awk '{print $1}' /proc/modules | sort | tr '\n' ' ')"
    } > $B/manifest.txt
    nohup sh /data/repro/lab_sarm2.sh _run "$TAG" "$NC" "$NF" "$ROUNDS" "$IVL" </dev/null >$B/supervise.log 2>&1 &
    echo $! > $B/supervisor.pid
    echo "STARTED tag=$TAG supervisor=$(cat $B/supervisor.pid)"
    ;;
  _run) do_run "$2" "$3" "$4" "$5" "$6" ;;
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
    for p in $(cat $B/pids.txt 2>/dev/null); do [ "$(isbin $p)" = "1" ] && kill -9 $p 2>/dev/null; done
    echo DONE > $B/state; echo "STOPPED $TAG"
    ;;
  *) echo "usage: $0 start|status|stop <tag> ..."; exit 1;;
esac
