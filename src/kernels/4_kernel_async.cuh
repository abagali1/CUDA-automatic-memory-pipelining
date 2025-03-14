#pragma once

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cuda_runtime.h>

#include <cuda/barrier>
#include <cooperative_groups.h>
#include <cooperative_groups/memcpy_async.h>

#define CEIL_DIV(M, N) (((M) + (N)-1) / (N))

namespace cg = cooperative_groups;

template <const int BLOCKSIZE>
__global__ void sgemm_shared_mem_block_async(int M, int N, int K, float alpha,
                                       const float *A, const float *B,
                                       float beta, float *C) {
  // the output block that we want to compute in this threadblock
  const uint cRow = blockIdx.y;
  const uint cCol = blockIdx.x;

  auto group = cg::this_thread_block();
  auto tile = cg::tiled_partition<BLOCKSIZE>(group);

  // allocate buffer for current block in fast shared mem
  // shared mem is shared between all threads in a block
  __shared__ float As[BLOCKSIZE][BLOCKSIZE];
  __shared__ float Bs[BLOCKSIZE][BLOCKSIZE];


  // the inner row & col that we're accessing in this thread
  const uint threadCol = threadIdx.x;
  const uint threadRow = threadIdx.y;

  // advance pointers to the starting positions
  A += cRow * BLOCKSIZE * K;                    // row=cRow, col=0
  B += cCol * BLOCKSIZE;                        // row=0, col=cCol
  C += cRow * BLOCKSIZE * N + cCol * BLOCKSIZE; // row=cRow, col=cCol

  float tmp = 0.0;
  // group.sync();
  for (int bkIdx = 0; bkIdx < K ; bkIdx += BLOCKSIZE) {
    // Have each thread load one of the elements in A & B
    // Make the threadCol (=threadIdx.x) the consecutive index
    // to allow global memory access coalescing
    // __syncthreads();
    // As[threadRow * BLOCKSIZE + threadCol] = A[threadRow * K + threadCol];
    // Bs[threadRow * BLOCKSIZE + threadCol] = B[threadRow * N + threadCol];
    // __syncthreads();

    cg::memcpy_async(
      tile,
      As[tile.meta_group_rank()],
      A + (tile.meta_group_rank() * K),
      cuda::aligned_size_t<16>(sizeof(float) * tile.size())
    );

    cg::memcpy_async(
      tile,
      Bs[tile.meta_group_rank()],
      B + (tile.meta_group_rank() * K),
      cuda::aligned_size_t<16>(sizeof(float) * tile.size())
    );

    // if(cRow == 0 && cCol == 0){
    //   printf("Tx: %d Ty: %d MR: %d\n", threadIdx.x, threadIdx.y, tile.group_meta_rank());
    // }

    cg::wait(group);

    // block threads in this block until cache is fully populated
    A += BLOCKSIZE;
    B += BLOCKSIZE * N;

    // execute the dotproduct on the currently cached block
    for (int dotIdx = 0; dotIdx < BLOCKSIZE; ++dotIdx) {
      tmp += As[threadRow][dotIdx] *
             Bs[dotIdx][threadCol];
    }
    __syncthreads();
  }
  C[threadRow * N + threadCol] = tmp;
}
