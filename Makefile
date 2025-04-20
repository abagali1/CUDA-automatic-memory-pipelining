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
	@cd $(CU_DIR) && nvcc -o sgemm -keep -src-in-ptx -arch=sm_80 -lineinfo -g -O0 -I../src ../sgemm.cu ../src/runner.cu

gemm_ir:
	@mkdir -p $(IR_DIR)
	@cd $(IR_DIR) && clang++ --cuda-gpu-arch=sm_80 --cuda-device-only -emit-llvm -I../src -S ../src/runner.cu -Xclang -disable-O0-optnone -Xclang -fcuda-allow-variadic-functions -D_LIBCUDACXX_HAS_CUDA_ATOMIC_IMPL -g
	@cd $(IR_DIR) && clang++ --cuda-gpu-arch=sm_80 --cuda-device-only -emit-llvm -I../src -c ../src/runner.cu -Xclang -disable-O0-optnone -Xclang -fcuda-allow-variadic-functions -D_LIBCUDACXX_HAS_CUDA_ATOMIC_IMPL -g


pass:
	@mkdir -p $(PASS_DIR)
	@cd $(PASS_DIR) && cmake .. && make

apply_pass: pass gemm_ir
	@cd $(PASS_DIR)
	@opt -load-pass-plugin pipepass/PipePass.so -passes=pipe ../$(IR_DIR)/*.bc -o pipelined.bc
	@llc -march=

clean:
	@rm -rf $(CU_DIR)
	@rm -rf $(IR_DIR)
	@rm -rf $(PASS_DIR)
