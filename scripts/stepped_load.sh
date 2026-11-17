#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Run a stepped traffic profile (idle -> bulk UDP -> idle, repeated) while
# sampling the live r8169 RX interrupt moderation level at ~5 Hz.
#
# usage: stepped_load.sh -p PEER [-d DEV] [-o CSV] [-c CYCLES] [-b RATE]
#   -p PEER    address of the peer running iperf3 -s
#   -d DEV     network interface (default enp3s0)
#   -o CSV     output CSV file   (default results/phase4/stepped_load.csv)
#   -c CYCLES  number of idle-load-idle cycles (default 2)
#   -b RATE    UDP offered load during burst   (default 600M)

set -eu

here=$(cd "$(dirname "$0")" && pwd)
PEER=""
DEV=enp3s0
CSV=results/phase4/stepped_load.csv
CYCLES=2
RATE=600M

usage() {
	sed -n '/^# usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 2
}

while getopts "p:d:o:c:b:h" opt; do
	case $opt in
	p) PEER=$OPTARG ;;
	d) DEV=$OPTARG ;;
	o) CSV=$OPTARG ;;
	c) CYCLES=$OPTARG ;;
	b) RATE=$OPTARG ;;
	*) usage ;;
	esac
done

[ -n "$PEER" ] || usage
mkdir -p "$(dirname "$CSV")"

sampler_pid=""
cleanup() {
	[ -z "$sampler_pid" ] || kill "$sampler_pid" 2>/dev/null || true
	pkill -x iperf3 2>/dev/null || true
}
trap cleanup EXIT

ethtool -C "$DEV" adaptive-rx on
if ! iperf3 -c "$PEER" -t 1 -R >/dev/null 2>&1; then
	echo "FAIL: cannot reach iperf3 on $PEER" >&2
	exit 1
fi

echo "Sampling $DEV to $CSV (cycles=$CYCLES, burst=$RATE)..."
bash "$here/sample_level.sh" "$DEV" 0.2 > "$CSV" &
sampler_pid=$!

for c in $(seq 1 "$CYCLES"); do
	echo "[cycle $c/$CYCLES] 10s idle..."
	sleep 10
	echo "[cycle $c/$CYCLES] 10s UDP burst ($RATE)..."
	iperf3 -c "$PEER" -R -u -b "$RATE" -t 10 >/dev/null 2>&1
	echo "[cycle $c/$CYCLES] 10s idle (observing decay)..."
	sleep 10
done

kill "$sampler_pid" 2>/dev/null || true
wait "$sampler_pid" 2>/dev/null || true
sampler_pid=""
echo "Done. Saved $(wc -l < "$CSV") samples to $CSV"