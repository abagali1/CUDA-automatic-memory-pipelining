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
  // the output block that we want to compute in this threadblock24327516
  const uint cRow = blockIdx.y;
  const uint cCol = blockIdx.x;

  auto group = cg::this_thread_block();
  auto tile = cg::tiled_partition<BLOCKSIZE>(group);
  auto thread = cg::this_thread();

  // allocate buffer for current block in fast shared mem
  // shared mem is shared between all threads in a block
  __shared__ float As[2][BLOCKSIZE][BLOCKSIZE];
  __shared__ float Bs[2][BLOCKSIZE][BLOCKSIZE];
  // __shared__ cuda::pipeline_shared_state<cuda::thread_scope_block, 2> shared_state;
  // auto pipe = cuda::make_pipeline(group, &shared_state);
  cuda::pipeline<cuda::thread_scope_thread> pipe = cuda::make_pipeline();


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

    cuda::memcpy_async(thread, &As[stage][threadRow][threadCol], &A[threadRow * K + threadCol], 4, pipe);
    cuda::memcpy_async(thread, &Bs[stage][threadRow][threadCol], &B[threadRow * K + threadCol], 4, pipe); 

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
    printf("A[%d, %d] => %lf\n", threadRow, threadCol, As[stage][threadRow][threadCol]);
    printf("B[%d, %d] => %lf\n", threadRow, threadCol, Bs[stage][threadRow][threadCol]);
    __syncthreads();
    printf("POST A[%d, %d] => %lf\n", threadRow, threadCol, As[stage][threadRow][threadCol]);
    printf("POST B[%d, %d] => %lf\n", threadRow, threadCol, Bs[stage][threadRow][threadCol]);
    tmp += compute<BLOCKSIZE>(As[stage], Bs[stage], threadRow, threadCol);
    __syncthreads();

    if(fetch_batch + compute_batch < batch_sz){
      cuda::memcpy_async(thread, &As[stage][threadRow][threadCol], &A[threadRow * K + threadCol], 4, pipe);
      cuda::memcpy_async(thread, &Bs[stage][threadRow][threadCol], &B[threadRow * K + threadCol], 4, pipe);
      asm volatile(
        "cp.async.commit_group;\n"
      );
      A += BLOCKSIZE;
      B += BLOCKSIZE * N;
    }
  }
  C[threadRow * N + threadCol] = tmp;
}

/*
  #pragma unroll 1
  for (size_t compute_batch = 0, fetch_batch = 0; compute_batch < batch_sz; ++compute_batch) {
    // The outer loop iterates over the computation of the batches
    #pragma unroll 2
    for (; fetch_batch < batch_sz && fetch_batch < (compute_batch + 2); ++fetch_batch) {
        // This inner loop iterates over the memory transfers, making sure that the pipeline is always full
        size_t stage = fetch_batch % 2;

        // pipe.producer_acquire();
        // asm volatile(
        //   "cp.async.cg.shared.global [%0], [%1], 16, 16;\n"
        //   :
        //   : "r"(static_cast<std::uint32_t>(__cvta_generic_to_shared(As[stage][tile.meta_group_rank()]))),
        //     "l"(A + (tile.meta_group_rank() * K))
        //   : "memory"
        // );

        // asm volatile(
        //   "cp.async.cg.shared.global [%0], [%1], 16, 16;\n"
        //   :
        //   : "r"(static_cast<std::uint32_t>(__cvta_generic_to_shared(Bs[stage][tile.meta_group_rank()]))),
        //     "l"(B + (tile.meta_group_rank() * K))
        //   : "memory"
        // );
        cuda::memcpy_async(thread, &As[stage][threadRow][threadCol], &A[threadRow * K + threadCol], 4, pipe);
        cuda::memcpy_async(thread, &Bs[stage][threadRow][threadCol], &B[threadRow * K + threadCol], 4, pipe);

        // cuda::memcpy_async(tile, As[stage][tile.meta_group_rank()], A + (tile.meta_group_rank() * K),  cuda::aligned_size_t<128>(sizeof(float) * BLOCKSIZE), pipe);
        // cuda::memcpy_async(tile, Bs[stage][tile.meta_group_rank()], B + (tile.meta_group_rank() * K),  cuda::aligned_size_t<128>(sizeof(float) * BLOCKSIZE), pipe);

        // asm volatile(
        //   "cp.async.commit_group;\n"
        // );
        pipe.producer_commit();

        A += BLOCKSIZE;
        B += BLOCKSIZE * N;
    }
    int shared_idx = compute_batch % 2;
    // pipe.consumer_wait();
    cuda::pipeline_consumer_wait_prior<1>(pipe);
    // asm volatile("cp.async.wait_group 1;\n");
    // printf("A[%d, %d] => %lf\n", threadRow, threadCol, As[shared_idx][threadRow][threadCol]);
    // printf("B[%d, %d] => %lf\n", threadRow, threadCol, Bs[shared_idx][threadRow][threadCol]);
    __syncthreads();
    tmp += compute<BLOCKSIZE>(As[shared_idx], Bs[shared_idx], threadRow, threadCol);
    __syncthreads();
    // pipe.consumer_release();
  }
  C[threadRow * N + threadCol] = tmp;
}
*/
