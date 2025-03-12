EECS 570 Final Project

# Building project

* ssh into greatlakes
* clone folder and cd into folder

```
module load cuda/12.6
mkdir build && cd build
cmake ..
make 
```

This will create the `sgemm` executable


# Running on Slurm

* from project base directory

```
sbatch submit.sh
```

## Changing submit.sh

Two lines:

```
./build/sgemm <number>
./gen_benchmark_results.sh
```

Only uncomment one line. First line will run individual kernel, second line will run all benchmarks

### gen_benchmark_results.sh

Line 11:
```bash
for kernel in {1..4}; do
```

Change `{1..4}` accordingly to run the benchmarks you want. MUST start at 1.

After running `gen_benchmark_results.sh` through `sbatch` run `python3 plot_benchmark_results.py` to generate plot (DO NOT run python script through Slurm)

# Kernel Descriptions

1) Uncoalesced memory access 
2) Coalesced memory access
3) Basic shared-memory tiled 
4) Async shared-memory tiled (NO overlap)
5) Overlaped async shared-memory tiled (i.e producer-consumer) 


# Common Slurm commands

View your running jobs
```bash
squeue --user=<uniqname>
```

View running jobs on `spgpu` partition
```bash
squeue --partition=spgpu
```

View running jobs in EECS 570 class account
```bash
squeue --account=eecs570s001wn25_class
```

View billing information for 570 class
```bash
my_account_billing eecs570s001w25_class
```

Cancel a Slurm job
```bash
scancel <job_id>
```
* When you submit a job using `sbatch` it will output the job id
* Alternatively you can find the job id using one of the `squeue` commands above

