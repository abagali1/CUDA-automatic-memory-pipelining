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
__global__ void sgemm_shared_mem_block_async_overlap(int M, int N, int K, float alpha,
                                       const float *A, const float *B,
                                       float beta, float *C) {
  // the output block that we want to compute in this threadblock
  const uint cRow = blockIdx.x;
  const uint cCol = blockIdx.y;

  auto group = cg::this_thread_block();
  auto tile = cg::tiled_partition<BLOCKSIZE>(group);

  // allocate buffer for current block in fast shared mem
  // shared mem is shared between all threads in a block
  __shared__ float As_buf[2][BLOCKSIZE][BLOCKSIZE];
  __shared__ float Bs_buf[2][BLOCKSIZE][BLOCKSIZE];


  // the inner row & col that we're accessing in this thread
  const uint threadCol = threadIdx.x;
  const uint threadRow = threadIdx.y;

  // advance pointers to the starting positions
  A += cRow * BLOCKSIZE * K;                    // row=cRow, col=0
  B += cCol * BLOCKSIZE;                        // row=0, col=cCol
  C += cRow * BLOCKSIZE * N + cCol * BLOCKSIZE; // row=cRow, col=cCol

  // First pre-load the first shared mems
  cg::memcpy_async(
    tile,
    As_buf[0][tile.meta_group_rank()],
    A + (tile.meta_group_rank() * K),
    cuda::aligned_size_t<128>(sizeof(float) * tile.size())
  );

  cg::memcpy_async(
    tile,
    Bs_buf[0][tile.meta_group_rank()],
    B + (tile.meta_group_rank() * N),
    cuda::aligned_size_t<128>(sizeof(float) * tile.size())
  );
  A += BLOCKSIZE;
  B += BLOCKSIZE * N;
  cg::wait(group);
  float tmp = 0.0;
  int cur_buf_idx = 1; // 1 becuase we just did 0
  int prev_buf_idx = 0;
  int numtiles = CEIL_DIV(K, BLOCKSIZE);
  for (int i = 1; i < numtiles; ++i) {  
    // Load the next iteration
    cg::memcpy_async(
      tile,
      As_buf[cur_buf_idx][tile.meta_group_rank()],
      A + (tile.meta_group_rank() * K),
      cuda::aligned_size_t<128>(sizeof(float) * tile.size())
    );

    cg::memcpy_async(
      tile,
      Bs_buf[cur_buf_idx][tile.meta_group_rank()],
      B + (tile.meta_group_rank() * N),
      cuda::aligned_size_t<128>(sizeof(float) * tile.size())
    );


    // block threads in this block until cache is fully populated
    A += BLOCKSIZE;
    B += BLOCKSIZE * N;

    // execute the dotproduct on the currently 
    for (int dotIdx = 0; dotIdx < BLOCKSIZE; ++dotIdx) {
      tmp += As_buf[prev_buf_idx][threadRow][dotIdx] *
             Bs_buf[prev_buf_idx][dotIdx][threadCol];
    }
    // swap cur and prev
    int tmp_idx = prev_buf_idx;
    prev_buf_idx    = cur_buf_idx;
    cur_buf_idx     = tmp_idx;

    cg::wait(tile);
    __syncthreads();    
  }

  // final iteration
  for (int dotIdx = 0; dotIdx < BLOCKSIZE; ++dotIdx) {
    tmp += As_buf[prev_buf_idx][threadRow][dotIdx] *
           Bs_buf[prev_buf_idx][dotIdx][threadCol];
  }
  // No syncthreads needed because we are done with the shared mem
  C[threadRow * N + threadCol] = tmp;
}
