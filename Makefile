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
	cd $(IR_DIR) && clang++ --cuda-gpu-arch=sm_80 --cuda-device-only -emit-llvm -S ../simplest_kernel.cu -o simplest_kernel_dev.ll -Xclang -disable-O0-optnone -Xclang -fcuda-allow-variadic-functions -D_LIBCUDACXX_HAS_CUDA_ATOMIC_IMPL -g

gemm:
	@mkdir -p $(CU_DIR)
	@cd $(CU_DIR) && nvcc -o sgemm -keep -src-in-ptx -arch=sm_80 -lineinfo -g -O0 -I../src ../sgemm.cu

gemm_ir:
	@mkdir -p $(IR_DIR)
	@cd $(IR_DIR) && clang++ --cuda-gpu-arch=sm_80 --cuda-path=/sw/pkgs/arc/cuda/11.8.0 --cuda-device-only -emit-llvm -c ../sgemm.cu ../src/kernels.cu -Xclang -disable-O0-optnone -Xclang -fcuda-allow-variadic-functions -D_LIBCUDACXX_HAS_CUDA_ATOMIC_IMPL -g
	@cd $(IR_DIR) && clang++ --cuda-gpu-arch=sm_80 --cuda-path=/sw/pkgs/arc/cuda/11.8.0 --cuda-host-only  ../sgemm.cu ../src/kernels.cu -lcudart -L/sw/pkgs/arc/cuda/11.8.0/lib64
	@cd $(IR_DIR) && opt -S -passes='loop-simplify,mem2reg' sgemm_device_pre.o -o sgemm_device_post.o
	# clang++ --cuda-gpu-arch=sm_80 --cuda-path=/sw/pkgs/arc/cuda/11.8.0 sgemm.cu src/kernels.cu -lcudart -L/sw/pkgs/arc/cuda/11.8.0/lib64 -Xclang -disable-O0-optnone -Xclang -fcuda-allow-variadic-functions -D_LIBCUDACXX_HAS_CUDA_ATOMIC_IMPL -g

viz: gemm_ir
	@cd $(IR_DIR) && llvm-extract -func=_Z22sgemm_shared_mem_blockILi32EEviiifPKfS1_fPf sgemm_device_post.o -o sync.ll
	@cd $(IR_DIR) && opt -passes="dot-cfg" -disable-output sync.ll
	@cd $(IR_DIR) && cat ._Z22sgemm_shared_mem_blockILi32EEviiifPKfS1_fPf.dot  | dot -Tpdf > sync.pdf
	@cd $(IR_DIR) && llvm-extract -func=_Z36sgemm_shared_mem_block_async_overlapILi32EEviiifPKfS1_fPf sgemm_device_post.o -o async.ll
	@cd $(IR_DIR) && opt -passes="dot-cfg" -disable-output async.ll
	@cd $(IR_DIR) && cat ._Z36sgemm_shared_mem_block_async_overlapILi32EEviiifPKfS1_fPf.dot  | dot -Tpdf > async.pdf

pass:
	@mkdir -p $(PASS_DIR)
	@cd $(PASS_DIR) && cmake -DCMAKE_PREFIX_PATH=$$HOME/llvm-install .. && make

apply_pass: pass gemm_ir
	@opt -S -load-pass-plugin $(PASS_DIR)/pipepass/PipePass.so -passes="pipe" $(IR_DIR)/sgemm_device_post.o -o $(IR_DIR)/sgemm_device_pipelined.o
	@cd $(IR_DIR) && llc -march=nvptx64 -mcpu=sm_80 sgemm_device_pipelined.o -o sgemm_device.ptx
	# @cd $(IR_DIR) && nvcc -arch=sm_80 --cubin sgemm_device.ptx
	# @cd $(IR_DIR) && nvcc -arch=sm_80 sgemm_device.cubin -o sgemm.o --device-link
	# @cd $(IR_DIR) && nvcc -arch=sm_80 -I../src/ ../sgemm.cu sgemm.o -o sgemm_opt --ptxas-options=-v

clean:
	@rm -rf $(CU_DIR)
	@rm -rf $(IR_DIR)
	@rm -rf $(PASS_DIR)
