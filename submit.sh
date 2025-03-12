#!/bin/bash
#SBATCH --job-name=gemm_profile
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --mem-per-cpu=1000m 
#SBATCH --account=eecs570s001w25_class
#SBATCH --partition=spgpu
#SBATCH --gpus-per-node=1

start_time=$(date +%s)
module load cuda/12.6

./build/sgemm 4 | tee benchmark_results/4_output.txt
# ./gen_benchmark_results.sh

end_time=$(date +%s)
runtime=$((end_time - start_time))
echo "Total job runtime: $runtime seconds"
