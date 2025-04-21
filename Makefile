.PHONY: all build debug clean profile bench cuobjdump

NVCC := nvcc 

PASS_DIR := build
CU_DIR := build_cuda
IR_DIR := build_ir

all: gemm

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
	@cd $(IR_DIR) && clang++ --cuda-gpu-arch=sm_80 --cuda-device-only -emit-llvm -I../src -S ../sgemm.cu -o sgemm_device.o -Xclang -disable-O0-optnone -Xclang -fcuda-allow-variadic-functions -D_LIBCUDACXX_HAS_CUDA_ATOMIC_IMPL -g

pass:
	@mkdir -p $(PASS_DIR)
	@cd $(PASS_DIR) && cmake -DCMAKE_PREFIX_PATH=$$HOME/llvm-install .. && make

apply_pass: pass gemm_ir
	# @opt -load-pass-plugin pipepass/PipePass.so -passes=pipe ../$(IR_DIR)/*.bc -o pipelined.bc
	@cd $(IR_DIR) && llc -march=nvptx64 -mcpu=sm_80 sgemm_device.o -o sgemm_device.ptx
	@cd $(IR_DIR) && nvcc -arch=sm_80 --cubin sgemm_device.ptx
	@cd $(IR_DIR) && nvcc -arch=sm_80 --device-link sgemm_device.cubin -o sgemm.o
	@cd $(IR_DIR) && nvcc -arch=sm_80 -I../src/ ../sgemm.cu sgemm.o -o sgemm_opt

clean:
	@rm -rf $(CU_DIR)
	@rm -rf $(IR_DIR)
	@rm -rf $(PASS_DIR)
