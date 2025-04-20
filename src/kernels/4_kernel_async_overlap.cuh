#pragma once

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cuda_runtime.h>

#include <cuda/barrier>
#include <cuda/pipeline>
#include <cooperative_groups.h>

#pragma nv_diag_suppress static_var_with_dynamic_init

#define CEIL_DIV(M, N) (((M) + (N)-1) / (N))

namespace cg = cooperative_groups;

template <const int BLOCKSIZE>
__device__ __forceinline__ float compute(const float As[BLOCKSIZE][BLOCKSIZE], const float Bs[BLOCKSIZE][BLOCKSIZE], const uint threadRow, const uint threadCol){
  float tmp = 0.0f;
  for (int dotIdx = 0; dotIdx < BLOCKSIZE; ++dotIdx) {
    tmp += As[threadRow][dotIdx] *
           Bs[dotIdx][threadCol];
  }
  return tmp;
}

template <const int BLOCKSIZE>
__global__ void sgemm_shared_mem_block_async_overlap(int M, int N, int K, float alpha,
                                       const float *A, const float *B,
                                       float beta, float *C) {
  // the output block that we want to compute in this threadblock
  const uint cRow = blockIdx.y;
  const uint cCol = blockIdx.x;

  // auto group = cg::this_thread_block();
  // auto tile = cg::tiled_partition<BLOCKSIZE>(group);
  // auto thread = cg::this_thread();

  // allocate buffer for current block in fast shared mem
  // shared mem is shared between all threads in a block
  __shared__ float As[2][BLOCKSIZE][BLOCKSIZE];
  __shared__ float Bs[2][BLOCKSIZE][BLOCKSIZE];
  // __shared__ cuda::pipeline_shared_state<cuda::thread_scope_block, 2> shared_state;
  // auto pipe = cuda::make_pipeline(group, &shared_state);
  // cuda::pipeline<cuda::thread_scope_thread> pipe = cuda::make_pipeline();


  // the inner row & col that we're accessing in this thread
  const uint threadCol = threadIdx.x;
  const uint threadRow = threadIdx.y;

  // advance pointers to the starting positions
  A += cRow * BLOCKSIZE * K;                    // row=cRow, col=0
  B += cCol * BLOCKSIZE;                        // row=0, col=cCol
  C += cRow * BLOCKSIZE * N + cCol * BLOCKSIZE; // row=cRow, col=cCol

  float tmp = 0.0f;
  size_t batch_sz = M / BLOCKSIZE;
  size_t stage;
  size_t fetch_batch;

  for(fetch_batch=0;fetch_batch < 2 && fetch_batch < batch_sz;fetch_batch++){
    stage = fetch_batch % 2;

    // cuda::memcpy_async(thread, &As[stage][threadRow][threadCol], &A[threadRow * K + threadCol], sizeof(float), pipe);
    // cuda::memcpy_async(thread, &Bs[stage][threadRow][threadCol], &B[threadRow * K + threadCol], sizeof(float), pipe);

    asm volatile(
      "cp.async.ca.shared.global [%0], [%1], 4, 4;\n"
      :
      : "r"(static_cast<std::uint32_t>(__cvta_generic_to_shared(&As[stage][threadRow][threadCol]))),
        "l"(&A[threadRow * K + threadCol])
      : "memory"
    );

    asm volatile(
      "cp.async.ca.shared.global [%0], [%1], 4, 4;\n"
      :
      : "r"(static_cast<std::uint32_t>(__cvta_generic_to_shared(&Bs[stage][threadRow][threadCol]))),
        "l"(&B[threadRow * K + threadCol])
      : "memory"
    );

    // pipe.producer_commit();
    asm volatile(
        "cp.async.commit_group;\n"
    );
    A += BLOCKSIZE;
    B += BLOCKSIZE * N; 
  }

  for(size_t compute_batch = 0;compute_batch < batch_sz;compute_batch++){
    stage = compute_batch % 2;
    asm volatile(
      "cp.async.wait_group 1;\n"
    );
    // pipe.consumer_wait();
    // printf("A[%d, %d] => %f\n", threadRow, threadCol, As[stage][threadRow][threadCol]);
    // printf("B[%d, %d] => %f\n", threadRow, threadCol, Bs[stage][threadRow][threadCol]);

    __syncthreads();
    tmp += compute<BLOCKSIZE>(As[stage], Bs[stage], threadRow, threadCol);
    __syncthreads();
    // pipe.consumer_release();

    if(fetch_batch + compute_batch < batch_sz){
      // cuda::memcpy_async(thread, &As[stage][threadRow][threadCol], &A[threadRow * K + threadCol], sizeof(float), pipe);
      // cuda::memcpy_async(thread, &Bs[stage][threadRow][threadCol], &B[threadRow * K + threadCol], sizeof(float), pipe);

      asm volatile(
        "cp.async.ca.shared.global [%0], [%1], 4, 4;\n"
        :
        : "r"(static_cast<std::uint32_t>(__cvta_generic_to_shared(&As[stage][threadRow][threadCol]))),
          "l"(&A[threadRow * K + threadCol])
        : "memory"
      );

      asm volatile(
        "cp.async.ca.shared.global [%0], [%1], 4, 4;\n"
        :
        : "r"(static_cast<std::uint32_t>(__cvta_generic_to_shared(&Bs[stage][threadRow][threadCol]))),
          "l"(&B[threadRow * K + threadCol])
        : "memory"
      );

      // pipe.producer_commit();
      asm volatile(
        "cp.async.commit_group;\n"
      );
      A += BLOCKSIZE;
      B += BLOCKSIZE * N;
    }
  }
  C[threadRow * N + threadCol] = tmp;
}
