#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Generate Phase 4 figures from rx_bench.sh and stepped_load.sh CSVs.

usage: plot_results.py [-d RESULTS_DIR] [-s STEPPED_CSV] [-o FIG_DIR]
"""

import argparse
import csv
import os
import statistics as st
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


def parse_kv(text):
    out = {}
    for item in text.split(";"):
        if "=" in item:
            k, v = item.split("=", 1)
            try:
                out[k] = float(v)
            except ValueError:
                pass
    return out


def load_all(results_dir):
    data = {}
    if not os.path.isdir(results_dir):
        return data
    for label in sorted(os.listdir(results_dir)):
        path = os.path.join(results_dir, label, "summary.csv")
        if not os.path.isfile(path):
            continue
        rows = []
        with open(path) as f:
            for r in csv.DictReader(f):
                if r.get("status") != "ok":
                    continue
                r.update(parse_kv(r.get("result", "")))
                for col in ("irq_per_s", "net_rx_softirq_per_s",
                            "irq_cpu_busy_pct", "irq_cpu_softirq_pct"):
                    if r.get(col) not in (None, "", "-"):
                        r[col] = float(r[col])
                rows.append(r)
        data[label] = rows
    return data


def agg(rows, workload, param, metric):
    vals = [r[metric] for r in rows
            if r["workload"] == workload and r["param"] == param and metric in r]
    if not vals:
        return None, None
    return st.mean(vals), (st.stdev(vals) if len(vals) > 1 else 0.0)


def plot_udp(data, out_dir):
    configs = [c for c in ("stock", "off", "static-L1", "static-L2", "static-L3", "static-L4", "adaptive") if c in data]
    if not configs:
        return
    for w, title_prefix in (("udp", "Bulk UDP (1448B)"), ("udps", "Small-Packet UDP (100B)")):
        params = sorted({r["param"] for rows in data.values() for r in rows if r["workload"] == w},
                        key=lambda p: float(p.split("_")[0].rstrip("M")))
        if not params:
            continue
        fig, axes = plt.subplots(1, 2, figsize=(11, 4.3))
        for cfg in configs:
            xs, y_soft, e_soft, y_irq, e_irq = [], [], [], [], []
            for p in params:
                m_s, s_s = agg(data[cfg], w, p, "irq_cpu_softirq_pct")
                m_i, s_i = agg(data[cfg], w, p, "irq_per_s")
                if m_s is not None:
                    xs.append(p.split("_")[0])
                    y_soft.append(m_s); e_soft.append(s_s)
                    y_irq.append(m_i); e_irq.append(s_i)
            if xs:
                axes[0].errorbar(xs, y_soft, yerr=e_soft, marker="o", capsize=3, label=cfg)
                axes[1].errorbar(xs, y_irq, yerr=e_irq, marker="s", capsize=3, label=cfg)
        axes[0].set_title(f"{title_prefix}: IRQ CPU Softirq %")
        axes[0].set_xlabel("Offered Rate")
        axes[0].set_ylabel("Softirq Share (%)")
        axes[0].grid(True, alpha=0.3)
        axes[0].legend(fontsize=8)

        axes[1].set_title(f"{title_prefix}: Hardware Interrupts/s")
        axes[1].set_xlabel("Offered Rate")
        axes[1].set_ylabel("Interrupts / sec")
        axes[1].grid(True, alpha=0.3)
        fig.tight_layout()
        fig.savefig(os.path.join(out_dir, f"fig1_{w}_metrics.png"), dpi=160)
        plt.close(fig)


def plot_rr(data, out_dir):
    configs = [c for c in ("stock", "off", "static-L1", "static-L2", "static-L3", "static-L4", "adaptive") if c in data]
    if not configs:
        return
    fig, axes = plt.subplots(1, 2, figsize=(11, 4.3))
    for idx, (w, param, title) in enumerate((("rr", "64B", "Single-Flow TCP_RR (64B)"),
                                             ("rrp", "8x64B", "Parallel 8x TCP_RR (64B)"))):
        labels, lats, errs = [], [], []
        for cfg in configs:
            m, s = agg(data[cfg], w, param, "mean_lat_us")
            if m is not None:
                labels.append(cfg); lats.append(m); errs.append(s)
        if labels:
            axes[idx].bar(labels, lats, yerr=errs, capsize=4, color="#3b82f6", edgecolor="black")
            axes[idx].set_title(f"{title}: Mean Latency")
            axes[idx].set_ylabel("Mean Latency (us)")
            axes[idx].tick_params(axis="x", rotation=25)
            axes[idx].grid(True, axis="y", alpha=0.3)
    fig.tight_layout()
    fig.savefig(os.path.join(out_dir, "fig2_rr_latency.png"), dpi=160)
    plt.close(fig)


def plot_stepped(stepped_csv, out_dir):
    if not os.path.isfile(stepped_csv):
        return
    ts, usecs, levels = [], [], []
    with open(stepped_csv) as f:
        for r in csv.DictReader(f):
            try:
                ts.append(float(r["time_s"]))
                usecs.append(int(r["rx_usecs"]))
                levels.append(int(r["rx_timer_field"]))
            except (ValueError, KeyError):
                pass
    if not ts:
        return
    fig, ax = plt.subplots(figsize=(10, 3.6))
    ax.step(ts, usecs, where="post", linewidth=2, color="#10b981", label="Live rx-usecs (us)")
    ax.set_title("Stepped Load Response: Idle -> Bulk UDP -> Idle (5 Hz Register Trace)")
    ax.set_xlabel("Time (seconds)")
    ax.set_ylabel("RX Coalescing Timer (us)")
    ax.grid(True, alpha=0.3)
    ax.legend()
    fig.tight_layout()
    fig.savefig(os.path.join(out_dir, "fig3_stepped_load.png"), dpi=160)
    plt.close(fig)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-d", "--dir", default="results/phase4/final")
    ap.add_argument("-s", "--stepped", default="results/phase4/stepped_load.csv")
    ap.add_argument("-o", "--out", default="docs/figures")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    data = load_all(args.dir)
    plot_udp(data, args.out)
    plot_rr(data, args.out)
    plot_stepped(args.stepped, args.out)
    print(f"Saved figures to {args.out}")


if __name__ == "__main__":
    main()