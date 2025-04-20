#!/bin/bash
#SBATCH --job-name=gemm_profile
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --mem-per-cpu=32g 
#SBATCH --account=eecs570s001w25_class
#SBATCH --partition=spgpu
#SBATCH --gpus-per-node=1

start_time=$(date +%s)
module load cuda/11.8

# ./build/sgemm 4
# ./gen_benchmark_results.sh
ncu --set full -o profiling_data/smem_sync -f ./build/sgemm 2
# ./build/simplest_kernel

end_time=$(date +%s)
runtime=$((end_time - start_time))
echo "[SYNC] Total job runtime: $runtime seconds"
