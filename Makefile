.PHONY: all build debug clean profile bench cuobjdump

NVCC := nvcc 

PASS_DIR := build
CU_DIR := build_cuda
IR_DIR := build_ir

all: apply_pass

simple:
	@mkdir -p $(CU_DIR)
	@cd $(CU_DIR) && nvcc -o simplest_kernel -keep -src-in-ptx -arch=sm_80 -lineinfo -g -O0 ../simplest_kernel.cu

simple_ir:
	@mkdir -p $(IR_DIR)

gemm:
	@mkdir -p $(CU_DIR)
	@cd $(CU_DIR) && nvcc -o sgemm -keep -src-in-ptx -arch=sm_80 -lineinfo -g -O0 -I../src ../sgemm.cu

gemm_ir:
	@mkdir -p $(IR_DIR)
	@cd $(IR_DIR) && clang++ --cuda-gpu-arch=sm_80 --cuda-path=/sw/pkgs/arc/cuda/11.8.0 --cuda-device-only -emit-llvm -c ../src/kernels.cu -o sgemm_device_pre.o -Xclang -disable-O0-optnone -Xclang -fcuda-allow-variadic-functions -D_LIBCUDACXX_HAS_CUDA_ATOMIC_IMPL
	@cd $(IR_DIR) && clang++ --cuda-gpu-arch=sm_80 --cuda-path=/sw/pkgs/arc/cuda/11.8.0 --cuda-host-only -c ../sgemm.cu -o sgemm_host.o -lcudart -L/sw/pkgs/arc/cuda/11.8.0/lib64
	@cd $(IR_DIR) && opt -S -passes='loop-simplify,mem2reg' sgemm_device_pre.o -o sgemm_device_post.o
	# clang++ --cuda-gpu-arch=sm_80 --cuda-path=/sw/pkgs/arc/cuda/11.8.0 sgemm.cu src/kernels.cu -lcudart -L/sw/pkgs/arc/cuda/11.8.0/lib64 -Xclang -disable-O0-optnone -Xclang -fcuda-allow-variadic-functions -D_LIBCUDACXX_HAS_CUDA_ATOMIC_IMPL -g

viz: apply_pass
	@cd $(IR_DIR) && llvm-extract -func=sgemm_shared_mem_block sgemm_device_pipelined.o -o sync.ll
	@cd $(IR_DIR) && opt -passes="dot-cfg" -disable-output sync.ll
	@cd $(IR_DIR) && cat .sgemm_shared_mem_block.dot  | dot -Tpdf > sync.pdf
	@cd $(IR_DIR) && llvm-extract -func=sgemm_shared_mem_block_async_overlap sgemm_device_pipelined.o -o async.ll
	@cd $(IR_DIR) && opt -passes="dot-cfg" -disable-output async.ll
	@cd $(IR_DIR) && cat .sgemm_shared_mem_block_async_overlap.dot  | dot -Tpdf > async.pdf

pass:
	@mkdir -p $(PASS_DIR)
	@cd $(PASS_DIR) && cmake -DCMAKE_PREFIX_PATH=$$HOME/llvm-install .. && make

apply_pass: pass gemm_ir
	@opt -S -load-pass-plugin $(PASS_DIR)/pipepass/PipePass.so -passes="pipe" $(IR_DIR)/sgemm_device_post.o -o $(IR_DIR)/sgemm_device_pipelined.o
	@cd $(IR_DIR) && llc -march=nvptx64 -mcpu=sm_80 sgemm_device_pipelined.o -o sgemm_device.ptx
	@cd $(IR_DIR) && mkdir -p tmp
	@cd $(IR_DIR) && ../steps.sh

clean:
	@rm -rf $(CU_DIR)
	@rm -rf $(IR_DIR)
	@rm -rf $(PASS_DIR)
