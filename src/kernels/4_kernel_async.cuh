#pragma once

#include <algorithm>
#include <cstdio>
#include <cstdlib>

#include <cuda_runtime.h>
#include <cooperative_groups.h>
#include <cooperative_groups/memcpy_async.h>

#define CEIL_DIV(M, N) (((M) + (N)-1) / (N))

template <const int BLOCKSIZE>
__global__ void sgemm_shared_mem_block_async(int M, int N, int K, float alpha,
                                       const float *A, const float *B,
                                       float beta, float *C) {
  // the output block that we want to compute in this threadblock
  const uint cRow = blockIdx.y;
  const uint cCol = blockIdx.x;
  
  auto group = cooperative_groups::this_thread_block();

  // allocate buffer for current block in fast shared mem
  // shared mem is shared between all threads in a block
  __shared__ float As[BLOCKSIZE * BLOCKSIZE];
  __shared__ float Bs[BLOCKSIZE * BLOCKSIZE];

  // the inner row & col that we're accessing in this thread
  const uint threadCol = threadIdx.x;
  const uint threadRow = threadIdx.y;

  // advance pointers to the starting positions
  A += cRow * BLOCKSIZE * K;                    // row=cRow, col=0
  B += cCol * BLOCKSIZE;                        // row=0, col=cCol
  C += cRow * BLOCKSIZE * N + cCol * BLOCKSIZE; // row=cRow, col=cCol

  float tmp = 0.0;
  for (int bkIdx = 0; bkIdx < K / BLOCKSIZE; bkIdx ++) {
    // Have each thread load one of the elements in A & B
    // Make the threadCol (=threadIdx.x) the consecutive index
    // to allow global memory access coalescing
    // As[threadRow * BLOCKSIZE + threadCol] = A[threadRow * K + threadCol];
    // Bs[threadRow * BLOCKSIZE + threadCol] = B[threadRow * N + threadCol];

    cooperative_groups::memcpy_async(group, As, A, sizeof(float) * group.size());
    cooperative_groups::memcpy_async(group, Bs, B, sizeof(float) * group.size());

    // block threads in this block until cache is fully populated
    // __syncthreads();
    cooperative_groups::wait(group);
    A += BLOCKSIZE;
    B += BLOCKSIZE * N;

    // execute the dotproduct on the currently cached block
    for (int dotIdx = 0; dotIdx < BLOCKSIZE; ++dotIdx) {
      tmp += As[threadRow * BLOCKSIZE + dotIdx] *
             Bs[dotIdx * BLOCKSIZE + threadCol];
    }
    // need to sync again at the end, to avoid faster threads
    // fetching the next block into the cache before slower threads are done
    // __syncthreads();
    group.sync();
  }
  C[threadRow * N + threadCol] = tmp;
}
