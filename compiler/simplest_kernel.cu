#include <cuda_runtime.h>
#include <iostream>
#include <vector>
#include <sys/time.h>

#include <cuda/pipeline>
#include <cooperative_groups.h>
#include <cooperative_groups/memcpy_async.h>

void cudaCheck_f(cudaError_t error, const char *file, int line) {
  if (error != cudaSuccess) {
    printf("[CUDA ERROR] at file %s:%d:\n%s\n", file, line,
           cudaGetErrorString(error));
    exit(EXIT_FAILURE);
  }
};

bool floateq(float a, float b, float eps){
  return abs(a - b) < eps;
}

#define cudaCheck(err) (cudaCheck_f(err, __FILE__, __LINE__))

__device__ void compute(float* global_out, float shared_in) {
    // Computes using all values of current batch from shared memory.
    // Stores this thread's result back to global memory.
    // printf("COMPUTE: %d => %lf (s)\n", threadIdx.x, shared_in[threadIdx.x]);
    *(global_out + threadIdx.x) = 6.9f * shared_in + 4.20f;
}

__global__ void without_memcpy_async(float* global_out, float const* global_in, size_t size, size_t batch_sz) {
  auto grid = cooperative_groups::this_grid();
  auto block = cooperative_groups::this_thread_block();
  assert(size == batch_sz * grid.size()); // Exposition: input size fits batch_sz * grid_size

  __shared__ float shared[1024]; // block.size() * sizeof(float) bytes

  #pragma unroll 1
  for (size_t batch = 0; batch < batch_sz; ++batch) {
    // Compute the index of the current batch for this block in global memory:
    size_t block_batch_idx = batch * blockDim.x;
    size_t global_idx = block_batch_idx + threadIdx.x;
    shared[threadIdx.x] = global_in[global_idx];

    block.sync(); // Wait for all copies to complete
    // printf("%d => %lf (g), %lf (s)\n", threadIdx.x, global_in[global_idx], shared[local_idx]);
    compute(global_out + block_batch_idx, shared[threadIdx.x]); // Compute and write result to global memory
    block.sync(); // Wait for compute using shared memory to finish
  }
}


// __global__ void with_memcpy_async(float* global_out, float const* global_in, size_t size, size_t batch_sz) {
//   auto grid = cooperative_groups::this_grid();
//   auto block = cooperative_groups::this_thread_block();
//   assert(size == batch_sz * grid.size()); // Exposition: input size fits batch_sz * grid_size

//   __align__(16) __shared__ float shared[1024]; // block.size() * sizeof(float) bytes

//   // Whole thread-group cooperatively copies whole batch to shared memory:
//   #pragma unroll
//   for (size_t batch = 0; batch < batch_sz; ++batch) {
//     size_t block_batch_idx = grid.size() * batch;
//     cooperative_groups::memcpy_async(block, shared, global_in + block_batch_idx, cuda::aligned_size_t<16>(sizeof(float) * block.size()));
//     cooperative_groups::wait(block); // Joins all threads, waits for all copies to complete
//     compute(global_out + block_batch_idx, shared[threadIdx.x]);
//     block.sync();
//   }
// }

template<int block_dim, int num_stages>
__global__ void pipelined(float* dest, float const* src, size_t size) {
    // Read blockDim.x integers per pipeline stage
   __shared__  float smem[num_stages][block_dim];
 
    // Grid stride loop:
    int offset = blockIdx.x * blockDim.x;
    size_t stride = gridDim.x * blockDim.x;
 
    // No pipeline::shared_state needed
    // cuda::pipeline<cuda::thread_scope_thread> pipe = cuda::make_pipeline();
 
    // Load all pipeline stages.
    for (int stage = 0; stage < num_stages; ++stage) {
        // pipe.producer_acquire();
        size_t idx = offset + stage * stride + threadIdx.x;
        if (idx < size) {
          asm volatile(
            "cp.async.ca.shared.global [%0], [%1], %2, %3;\n"
            :
            : "r"(static_cast<std::uint32_t>(__cvta_generic_to_shared(&smem[stage][threadIdx.x]))),
              "l"(&src[idx]),
              "n"(sizeof(float)), "n"(sizeof(float))
            : "memory"
          );
          // cuda::memcpy_async(&smem[stage][threadIdx.x], &src[idx], sizeof(float), pipe);
        }
        asm volatile("cp.async.commit_group;");
        // pipe.producer_commit();
    }

    // At this point, there are `num_stages` commited into the pipeline. This is a loop.
    // invariant that is upheld throughout the loop.
    int stage = 0;
    for (size_t block_idx = offset; block_idx < size; block_idx += stride) {
        // Wait for the first stage to have completed loading, or equivalently: wait until
        // at most `num_stages - 1` stages are still loading.
        // cuda::pipeline_consumer_wait_prior<num_stages - 1>(pipe);
        asm volatile("cp.async.wait_group 1;");

        // __syncthreads is necessary if other threads want to read this thread's loaded data.
        // __syncthreads();
        compute(dest + block_idx, smem[stage][threadIdx.x]);
        __syncthreads();

        // Release the consumed stage.
        // pipe.consumer_release();

        // Pre-load data for `num_stages` into the future.
        // pipe.producer_acquire();
        // To ensure that the number of commited stages into the pipeline remains constant,
        // producer_acquire and producer_commit are called even if the load is out-of-bounds.
        size_t idx = block_idx + num_stages * stride + threadIdx.x;
        if (idx < size) {
              asm volatile(
                "cp.async.ca.shared.global [%0], [%1], %2, %3;\n"
                :
                : "r"(static_cast<std::uint32_t>(__cvta_generic_to_shared(&smem[stage][threadIdx.x]))),//  &smem[stage][threadIdx.x]), 
                  "l"(&src[idx]),
                  "n"(sizeof(float)), "n"(sizeof(float))
                : "memory"
            );
            // cuda::memcpy_async(&smem[stage][threadIdx.x], &src[idx], sizeof(float), pipe);
        }
        asm volatile("cp.async.commit_group;");
        // pipe.producer_commit();

        stage = (stage + 1) % num_stages;
    }
}


void randomize_matrix(float *mat, int N) {
  // NOTICE: Use gettimeofday instead of srand((unsigned)time(NULL)); the time
  // precision is too low and the same random number is generated.
  struct timeval time {};
  gettimeofday(&time, nullptr);
  for (int i = 0; i < N; i++) {
    float tmp = (float)(rand() % 5) + 0.01 * (rand() % 5);
    tmp = (rand() % 2 == 0) ? tmp : tmp * (-1.);
    mat[i] = tmp;
  }
}


int main(int argc, char **argv) {
  float *Xs, *Ys;
  float *Xs_d, *Ys_d;

  uint SIZE = 4096;

  Xs = (float *)malloc(SIZE * SIZE * sizeof(float));
  Ys = (float *)malloc(SIZE * SIZE * sizeof(float));

  cudaCheck(cudaMalloc((void **)&Xs_d, SIZE * SIZE * sizeof(float)));
  cudaCheck(cudaMalloc((void **)&Ys_d, SIZE * SIZE * sizeof(float)));

  randomize_matrix(Xs, SIZE*SIZE);

  cudaCheck(cudaMemcpy(Xs_d, Xs, SIZE*SIZE*sizeof(float), cudaMemcpyHostToDevice));
  cudaCheck(cudaGetLastError()); // Check for async errors during kernel run

  float elapsed_time;
  float num_times = 50;
  cudaEvent_t beg, end;
  cudaCheck(cudaEventCreate(&beg));
  cudaCheck(cudaEventCreate(&end));
  cudaCheck(cudaEventRecord(beg));
  for (int j = 0; j < num_times; j++) {
    // with_memcpy_async<<<1, 1024>>>(Ys_d, Xs_d, SIZE * SIZE, (SIZE*SIZE)/1024);
    pipelined<1024, 2><<<1, 1024>>>(Ys_d, Xs_d, SIZE*SIZE);
  }
  cudaCheck(cudaEventRecord(end));
  cudaCheck(cudaEventSynchronize(beg));
  cudaCheck(cudaEventSynchronize(end));
  cudaCheck(cudaEventElapsedTime(&elapsed_time, beg, end));
  elapsed_time /= 1000.; // Convert to seconds

  printf(
      "Average elapsed time: (%7.6f) s.\n\n", elapsed_time / num_times);
  fflush(stdout);

  cudaCheck(cudaMemcpy(Ys, Ys_d, SIZE * SIZE * sizeof(float), cudaMemcpyDeviceToHost));

  for(int i=0;i<SIZE*SIZE;i++){
    if(!floateq(Ys[i], 6.9f * Xs[i] + 4.20f, 0.001f)){
      printf("Validation Failed (%d)! %lf => %lf\n", i, Xs[i], Ys[i]);
      break;
    }
  }
  printf("Validation Pass!\n");

  cudaCheck(cudaDeviceSynchronize());

  cudaFree(Xs_d);
  cudaFree(Ys_d);
  free(Xs);
  free(Ys);
}
