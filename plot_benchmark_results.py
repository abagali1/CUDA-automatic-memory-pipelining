#!/usr/bin/env python3

import re
import matplotlib
import matplotlib.pyplot as plt
import seaborn as sn
import pandas as pd
from pathlib import Path

# this makes all plots look nicer, and high dpi
# sn.set_theme(style="whitegrid", font_scale=1.0, rc={"figure.dpi": 200})
# set a nicer font
# plt.rcParams["font.family"] = "serif"
# To set some sane defaults
matplotlib.style.use("fivethirtyeight")
matplotlib.style.use("seaborn")
matplotlib.rcParams["font.family"] = "monospace"
matplotlib.rcParams["figure.dpi"] = 200
plt.rcParams["savefig.facecolor"] = "white"
# sn.set_context("talk")

KERNEL_NAMES = {
    1: "Naive",
    2: "SMEM Baseline",
    3: "SMEM Async (no pipeline)",
    4: "SMEM Pipelined Async"
}


def parse_file(file):
    """
    The data we want to parse has this format:

    Average elapsed time: (0.005661) s, performance: (24277.4) GFLOPS. size: (4096).
    """
    with open(file, "r") as f:
        lines = [line.strip() for line in f.readlines()]

    data = {"size": [], "gflops": []}
    pattern = "Average elapsed time: \((.*?)\) s, performance: \((.*?)\) GFLOPS. size: \((.*?)\)."
    for line in lines:
        if r := re.match(pattern, line):
            data["size"].append(int(r.group(3)))
            data["gflops"].append(float(r.group(2)))
    return data


def plot(df: pd.DataFrame):
    """
    The dataframe has 3 columns: kernel, size, gflops

    We want to plot the gflops for each kernel, for each size as a single seaborn multi-line plot.
    """
    save_dir = Path.cwd()

    plt.figure(figsize=(18, 10))
    colors = sn.color_palette("husl", len(df["kernel"].unique()))
    sn.lineplot(data=df, x="size", y="gflops", hue="kernel", palette=colors)
    # also plot points, but without legend
    sn.scatterplot(data=df, x="size", y="gflops", hue="kernel", palette=colors, legend=False)

    # set ticks at actual sizes
    plt.xticks(df["size"].unique())
    # rotate xticks, and align them
    plt.xticks(rotation=45, ha="right", rotation_mode="anchor")
    # add small lines at the xticks

    # display the kernel names right next to the corresponding line
    for i, kernel in enumerate(df["kernel"].unique()):
        # right align the text
        plt.text(
            df[df["kernel"] == i+1]["size"].iloc[-1],
            df[df["kernel"] == i+1]["gflops"].iloc[-1] + 50,
            f"{i+1}:{KERNEL_NAMES[i+1]}",
            color=colors[i],
            horizontalalignment="left",
            weight="medium",
        )

    # turn of the legend
    plt.gca().get_legend().remove()

    plt.title("Performance of different kernels", fontsize=25)
    plt.xlabel("Matrix size (square, one side)", fontsize=20)
    plt.ylabel("GFLOPs/s", fontsize=20)
    plt.tight_layout()

    plt.savefig(save_dir / "benchmark_results.png")


if __name__ == "__main__":
    results_dir = Path("benchmark_results")
    assert results_dir.is_dir()

    data = []
    for filename in results_dir.glob("*.txt"):
        # filenames have the format: <kernel_nr>_output.txt
        if not filename.stem.split("_")[0].isdigit() and "_output" not in filename.stem:
            continue
        results_dict = parse_file(filename)
        kernel_nr = int(filename.stem.split("_")[0])
        for size, gflops in zip(results_dict["size"], results_dict["gflops"]):
            data.append({"kernel": kernel_nr, "size": size, "gflops": gflops})
    df = pd.DataFrame(data)

    plot(df)

    df = df[df["size"] == 4096].sort_values(by="gflops", ascending=True)[["kernel", "gflops"]]
    df["kernel"] = df["kernel"].map({k: f"{k}: {v}" for k, v in KERNEL_NAMES.items()})
    # df["relperf"] = df["gflops"] / df[df["kernel"] == "0: cuBLAS"]["gflops"].iloc[0]
    # df["relperf"] = df["relperf"].apply(lambda x: f"{x*100:.1f}%")
    # df.columns = ["Kernel", "GFLOPs/s", "Performance relative to cuBLAS"]
