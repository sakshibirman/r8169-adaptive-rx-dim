#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Interleaved benchmark runner for Phase 4 (plan-4 section 3.4).
# Prevents time-of-day or peer drift from aligning with one configuration.
#
# usage: run_matrix.sh -p PEER [-d DEV] [-o OUTDIR] [-r ROUNDS] [-v VISITS] [-t SECS] [-w WORKLOADS] [-u RATES] [-s SRATES]
#   -p PEER       peer IP address (running iperf3 -s and netserver)
#   -d DEV        network interface (default enp3s0)
#   -o OUTDIR     output directory  (default results/phase4/final)
#   -r ROUNDS     interleave rounds (default 4; with -v 3 gives 12 runs/cell)
#   -v VISITS     runs per visit    (default 3)
#   -t SECS       seconds per run   (default 20)
#   -w WORKLOADS  workloads list    (default "idle rr rrp tcp udp udps")
#   -u RATES      UDP rates         (default "100M 300M 600M 900M")
#   -s SRATES     UDPS rates        (default "50M 100M 150M 200M")
#   -S            skip stock module swap at start/end

set -eu

here=$(cd "$(dirname "$0")" && pwd)
PEER=""
DEV=enp3s0
OUTDIR=results/phase4/final
ROUNDS=4
VISITS=3
SECS=20
WORKLOADS="idle rr rrp tcp udp udps"
UDP_RATES="100M 300M 600M 900M"
UDPS_RATES="50M 100M 150M 200M"
SKIP_STOCK=0
MOD_PATH=/root/r8169-new-signed.ko

usage() {
	sed -n '/^# usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 2
}

while getopts "p:d:o:r:v:t:w:u:s:Sh" opt; do
	case $opt in
	p) PEER=$OPTARG ;;
	d) DEV=$OPTARG ;;
	o) OUTDIR=$OPTARG ;;
	r) ROUNDS=$OPTARG ;;
	v) VISITS=$OPTARG ;;
	t) SECS=$OPTARG ;;
	w) WORKLOADS=$OPTARG ;;
	u) UDP_RATES=$OPTARG ;;
	s) UDPS_RATES=$OPTARG ;;
	S) SKIP_STOCK=1 ;;
	*) usage ;;
	esac
done

[ -n "$PEER" ] || usage

wait_peer() {
	for _ in $(seq 1 45); do
		if iperf3 -c "$PEER" -t 1 -R >/dev/null 2>&1; then
			sleep 2
			return 0
		fi
		sleep 1
	done
	echo "FAIL: peer $PEER unreachable after module swap" >&2
	exit 1
}

set_config() {
	local cfg=$1
	case $cfg in
	off)
		ethtool -C "$DEV" adaptive-rx off
		ethtool -C "$DEV" rx-usecs 0 rx-frames 1
		;;
	static-L1)
		ethtool -C "$DEV" adaptive-rx off
		ethtool -C "$DEV" rx-usecs 40 rx-frames 0
		;;
	static-L2)
		ethtool -C "$DEV" adaptive-rx off
		ethtool -C "$DEV" rx-usecs 80 rx-frames 0
		;;
	static-L3)
		ethtool -C "$DEV" adaptive-rx off
		ethtool -C "$DEV" rx-usecs 200 rx-frames 0
		;;
	static-L4)
		ethtool -C "$DEV" adaptive-rx off
		ethtool -C "$DEV" rx-usecs 400 rx-frames 0
		;;
	adaptive)
		ethtool -C "$DEV" adaptive-rx on
		;;
	*)
		echo "unknown config: $cfg" >&2
		exit 1
		;;
	esac
}

run_bench() {
	local label=$1 n=$2
	bash "$here/rx_bench.sh" -l "$label" -p "$PEER" -d "$DEV" -o "$OUTDIR" \
		-n "$n" -t "$SECS" -w "$WORKLOADS" -u "$UDP_RATES" -s "$UDPS_RATES"
}

if [ "$SKIP_STOCK" -eq 0 ]; then
	echo "=== Loading STOCK module for initial baseline ==="
	rmmod r8169 && modprobe r8169
	wait_peer
	run_bench stock "$((ROUNDS * VISITS / 2))"

	echo "=== Loading PATCHED module ($MOD_PATH) ==="
	rmmod r8169 && insmod "$MOD_PATH"
	wait_peer
fi

CONFIGS="off static-L1 static-L2 static-L3 static-L4 adaptive"

for r in $(seq 1 "$ROUNDS"); do
	echo "=== Interleave round $r / $ROUNDS ==="
	for cfg in $CONFIGS; do
		echo "--- Config: $cfg (round $r) ---"
		set_config "$cfg"
		run_bench "$cfg" "$VISITS"
	done
done

if [ "$SKIP_STOCK" -eq 0 ]; then
	echo "=== Loading STOCK module for closing baseline ==="
	rmmod r8169 && modprobe r8169
	wait_peer
	run_bench stock "$((ROUNDS * VISITS / 2))"

	echo "=== Restoring PATCHED module ($MOD_PATH) ==="
	rmmod r8169 && insmod "$MOD_PATH"
	wait_peer
fi

echo "Matrix complete! Summarize with:"
echo "  python3 scripts/summarize_results.py -d $OUTDIR"