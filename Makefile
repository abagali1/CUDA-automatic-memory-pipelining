.PHONY: all build debug clean profile bench cuobjdump

NVCC := nvcc 

BUILD_DIR := build
IR_DIR := build_ir

all: gemm

simple:
	@mkdir -p $(BUILD_DIR)
	@cd $(BUILD_DIR) && nvcc -o simplest_kernel -keep -src-in-ptx -arch=sm_80 -lineinfo -g -O0 ../simplest_kernel.cu

simple_ir:
	@mkdir -p $(IR_DIR)
	cd $(IR_DIR) && clang++ --cuda-gpu-arch=sm_80 --cuda-device-only -emit-llvm -S ../simplest_kernel.cu -o simplest_kernel_dev.ll -Xclang -disable-O0-optnone -Xclang -fcuda-allow-variadic-functions -D_LIBCUDACXX_HAS_CUDA_ATOMIC_IMPL

gemm:
	@mkdir -p $(BUILD_DIR)
	@cd $(BUILD_DIR) && nvcc -o sgemm -keep -src-in-ptx -arch=sm_80 -lineinfo -g -O0 -I../src ../sgemm.cu ../src/runner.cu

gemm_ir:
	@mkdir -p $(IR_DIR)
	@cd $(IR_DIR) && clang++ --cuda-gpu-arch=sm_80 --cuda-device-only -emit-llvm -I../src -S ../sgemm.cu ../src/runner.cu -Xclang -disable-O0-optnone -Xclang -fcuda-allow-variadic-functions -D_LIBCUDACXX_HAS_CUDA_ATOMIC_IMPL

clean:
	@rm -rf $(BUILD_DIR)
	@rm -rf $(IR_DIR)

