#!/bin/bash


IR_DIR="build_ir"

make gemm_ir

# Apply the pass to the device bc code
opt -load-pass-plugin build/pipepass/PipePass.so -passes=pipe ${1}_device.bc -o ${1}_device.bc

# Convert rgb_device.bc to ptx
llc -march=nvptx64 -mcpu=${GPU_ARCH} ${1}_device.bc -o ${1}_device.ptx

# Convert rgb_device.ptx to cubin
nvcc --gpu-architecture=${GPU_ARCH} --cubin ${1}_device.ptx

# Dlink rgb_devic.cubin with rgb_host.o and generate a rgb object file
nvcc --gpu-architecture=${GPU_ARCH} --device-link ${1}_device.cubin ${1}_host.o -o ${1}.o

# Assemble the device code and main to generate an executable rgb.out
nvcc main.cu ${1}.o -o ${1}.out

# Run the executable
./${1}.out

# Remove redundant files
rm *.bc *.ptx *.o