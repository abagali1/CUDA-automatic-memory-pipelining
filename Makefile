.PHONY: all build debug clean profile bench cuobjdump

NVCC := nvcc 

BUILD_DIR := build

all: build

simple:
	@mkdir -p $(BUILD_DIR)
	@cd $(BUILD_DIR) && nvcc -o simplest_kernel -keep -src-in-ptx -arch=sm_80 ../simplest_kernel.cu 

gemm:
	@mkdir -p $(BUILD_DIR)
	@cd $(BUILD_DIR)
clean:
	@rm -rf $(BUILD_DIR)

FUNCTION := $$(cuobjdump -symbols build/sgemm | grep -i sgemm_shared_mem_block_async | awk '{print $$NF}')

cuobjdump: build
	@cuobjdump -arch sm_86 -sass -fun $(FUNCTION) build/sgemm | c++filt > build/cuobjdump.sass
	@cuobjdump -arch sm_86 -ptx -fun $(FUNCTION) build/sgemm | c++filt > build/cuobjdump.ptx

# Usage: make profile KERNEL=<integer> PREFIX=<optional string>
profile: build
	@ncu --set full --export $(BENCHMARK_DIR)/$(PREFIX)kernel_$(KERNEL) --force-overwrite $(BUILD_DIR)/sgemm $(KERNEL)

bench: build
	@bash gen_benchmark_results.sh
