#!/usr/bin/env bash

set -euo pipefail

# This scripts runs the ./sgemm binary for all exiting kernels, and logs
# the outputs to text files in benchmark_results/. Then it calls
# the plotting script

mkdir -p benchmark_results

for kernel in {1..4}; do
    echo ""
    ./build_cuda/sgemm $kernel | tee "benchmark_results/${kernel}_output.txt"
    sleep 2
done

# python3 plot_benchmark_results.py
