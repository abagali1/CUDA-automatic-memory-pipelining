#include <algorithm>
#include <cstdio>
#include <cstdlib>

#include <cuda_runtime.h>

#include <cuda/barrier>
#include <cooperative_groups.h>
#include <cooperative_groups/memcpy_async.h>

#define BLOCKSIZE 32
#define CEIL_DIV(M, N) (((M) + (N)-1) / (N))

namespace cg = cooperative_groups;

extern "C" __global__ void sgemm_naive(int M, int N, int K, float alpha, const float *A, const float *B, float beta, float *C) {
    const uint y = blockIdx.x * blockDim.x + threadIdx.x;
    const uint x = blockIdx.y * blockDim.y + threadIdx.y;

    // if statement is necessary to make things work under tile quantization
    if (x < M && y < N) {
        float tmp = 0.0;
        for (int i = 0; i < K; ++i) {
            tmp += A[x * K + i] * B[i * N + y];
        }
        // C = α*(A@B)+β*C
        C[x * N + y] = tmp; 
    }
}


extern "C" __global__ void sgemm_global_mem_coalesce(int M, int N, int K, float alpha, const float *A, const float *B, float beta, float *C) {
    // const int cRow = blockIdx.x * BLOCKSIZE + (threadIdx.x / BLOCKSIZE);
    // const int cCol = blockIdx.y * BLOCKSIZE + (threadIdx.x % BLOCKSIZE);
    const int cRow = blockIdx.y * BLOCKSIZE + threadIdx.y;
    const int cCol = blockIdx.x * BLOCKSIZE + threadIdx.x;

    // if statement is necessary to make things work under tile quantization
    if (cRow < M && cCol < N) {
        float tmp = 0.0;
        for (int i = 0; i < K; ++i) {
            tmp += A[cRow * K + i] * B[i * N + cCol];
        }
        C[cRow * N + cCol] = tmp;
    }
}

extern "C" __global__ void sgemm_shared_mem_block(int M, int N, int K, float alpha, const float *A, const float *B, float beta, float *C) {
    // the output block that we want to compute in this threadblock
    const uint cRow = blockIdx.x;
    const uint cCol = blockIdx.y;

    // allocate buffer for current block in fast shared mem
    // shared mem is shared between all threads in a block
    __shared__ float As[BLOCKSIZE * BLOCKSIZE];
    __shared__ float Bs[BLOCKSIZE * BLOCKSIZE];

    // the inner row & col that we're accessing in this thread
    const uint threadCol = threadIdx.x;// % BLOCKSIZE;
    const uint threadRow = threadIdx.y;// / BLOCKSIZE;

    // advance pointers to the starting positions
    // A += cRow * BLOCKSIZE * K;                    // row=cRow, col=0
    // B += cCol * BLOCKSIZE;                        // row=0, col=cCol
    C += cRow * BLOCKSIZE * N + cCol * BLOCKSIZE; // row=cRow, col=cCol

    float tmp = 0.0;
    int num_batches = M / BLOCKSIZE;
    for (int bkIdx = 0; bkIdx < num_batches; bkIdx += 1) {
        // Have each thread load one of the elements in A & B
        // Make the threadCol (=threadIdx.x) the consecutive index
        // to allow global memory access coalescing

        As[threadRow * BLOCKSIZE + threadCol] = A[(cRow * BLOCKSIZE * K) + (BLOCKSIZE * bkIdx) + threadRow * K + threadCol];
        Bs[threadRow * BLOCKSIZE + threadCol] = B[(cCol * BLOCKSIZE) + (BLOCKSIZE * N * bkIdx) + threadRow * N + threadCol];

        // block threads in this block until cache is fully populated
        __syncthreads();
        // A += BLOCKSIZE;
        // B += BLOCKSIZE * N;

        // execute the dotproduct on the currently cached block
        for (int dotIdx = 0; dotIdx < BLOCKSIZE; ++dotIdx) {
            tmp += As[threadRow * BLOCKSIZE + dotIdx] *
            Bs[dotIdx * BLOCKSIZE + threadCol];
        }
            // need to sync again at the end, to avoid faster threads
            // fetching the next block into the cache before slower threads are done
        __syncthreads();
    }
    C[threadRow * N + threadCol] = tmp;
}

extern "C" __global__ void sgemm_shared_mem_block_async(int M, int N, int K, float alpha, const float *A, const float *B, float beta, float *C) {
    // the output block that we want to compute in this threadblock
    const uint cRow = blockIdx.y;
    const uint cCol = blockIdx.x;

    auto group = cg::this_thread_block();
    auto tile = cg::tiled_partition<BLOCKSIZE>(group);

    // allocate buffer for current block in fast shared mem
    // shared mem is shared between all threads in a block
    __shared__ float As[BLOCKSIZE * BLOCKSIZE];
    __shared__ float Bs[BLOCKSIZE * BLOCKSIZE];


    // the inner row & col that we're accessing in this thread
    const uint threadCol = threadIdx.x;
    const uint threadRow = threadIdx.y;

    // advance pointers to the starting positions
    // A += cRow * BLOCKSIZE * K;                    // row=cRow, col=0
    // B += cCol * BLOCKSIZE;                        // row=0, col=cCol
    C += cRow * BLOCKSIZE * N + cCol * BLOCKSIZE; // row=cRow, col=cCol

    float tmp = 0.0;
    // group.sync();
    size_t num_batches = K / BLOCKSIZE;
    for (int bkIdx = 0; bkIdx < num_batches ; bkIdx += 1) {
        // Have each thread load one of the elements in A & B
        // Make the threadCol (=threadIdx.x) the consecutive index
        // to allow global memory access coalescing
        // __syncthreads();
        // As[threadRow * BLOCKSIZE + threadCol] = A[threadRow * K + threadCol];
        // Bs[threadRow * BLOCKSIZE + threadCol] = B[threadRow * N + threadCol];
        // __syncthreads();

        // cg::memcpy_async(
        // tile,
        // As[tile.meta_group_rank()],
        // A + (tile.meta_group_rank() * K),
        // cuda::aligned_size_t<128>(sizeof(float) * tile.size())
        // );

        // cg::memcpy_async(
        // tile,
        // Bs[tile.meta_group_rank()],
        // B + (tile.meta_group_rank() * K),
        // cuda::aligned_size_t<128>(sizeof(float) * tile.size())
        // );
        asm volatile(
          "cp.async.ca.shared.global [%0], [%1], 4, 4;\n"
          :
          : "r"(static_cast<std::uint32_t>(__cvta_generic_to_shared(&As[threadRow * BLOCKSIZE + threadCol]))),
            "l"(&A[(cRow * BLOCKSIZE * K) + (BLOCKSIZE * bkIdx) + threadRow * K + threadCol])
          : "memory"
        );

        asm volatile(
          "cp.async.ca.shared.global [%0], [%1], 4, 4;\n"
          :
          : "r"(static_cast<std::uint32_t>(__cvta_generic_to_shared(&Bs[threadRow * BLOCKSIZE + threadCol]))),
            "l"(&B[(cCol * BLOCKSIZE) + (BLOCKSIZE * N * bkIdx) + threadRow * N + threadCol])
          : "memory"
        );

        asm volatile(
          "cp.async.commit_group;\n"
        );

        asm volatile(
          "cp.async.wait_group 0;\n"
        );
        __syncthreads();
        // if(cRow == 0 && cCol == 0){
        //   printf("Tx: %d Ty: %d MR: %d\n", threadIdx.x, threadIdx.y, tile.group_meta_rank());
        // }

        // cg::wait(group);

        // block threads in this block until cache is fully populated
        // A += BLOCKSIZE;
        // B += BLOCKSIZE * N;

        // execute the dotproduct on the currently cached block
        for (int dotIdx = 0; dotIdx < BLOCKSIZE; ++dotIdx) {
            tmp += As[threadRow * BLOCKSIZE + dotIdx] *
            Bs[dotIdx * BLOCKSIZE + threadCol];
        }
        __syncthreads();
    }
    C[threadRow * N + threadCol] = tmp;
}


__device__ __forceinline__ float compute(const float As[BLOCKSIZE][BLOCKSIZE], const float Bs[BLOCKSIZE][BLOCKSIZE], const uint threadRow, const uint threadCol){
    float tmp = 0.0f;
    for (int dotIdx = 0; dotIdx < BLOCKSIZE; ++dotIdx) {
        tmp += As[threadRow][dotIdx] *
                Bs[dotIdx][threadCol];
    }
    return tmp;
}
  
extern "C" __global__ void sgemm_shared_mem_block_async_overlap(int M, int N, int K, float alpha, const float *A, const float *B, float beta, float *C) {
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
    // A += cRow * BLOCKSIZE * K;                    // row=cRow, col=0
    // B += cCol * BLOCKSIZE;                        // row=0, col=cCol
    C += cRow * BLOCKSIZE * N + cCol * BLOCKSIZE; // row=cRow, col=cCol
  
    float tmp = 0.0f;
    size_t batch_sz = M / BLOCKSIZE;
    size_t stage;
  
    // cuda::memcpy_async(thread, &As[stage][threadRow][threadCol], &A[threadRow * K + threadCol], sizeof(float), pipe);
    // cuda::memcpy_async(thread, &Bs[stage][threadRow][threadCol], &B[threadRow * K + threadCol], sizeof(float), pipe);
  
    asm volatile(
      "cp.async.ca.shared.global [%0], [%1], 4, 4;\n"
      :
      : "r"(static_cast<std::uint32_t>(__cvta_generic_to_shared(&As[0][threadRow][threadCol]))),
        "l"(&A[(cRow * BLOCKSIZE * K) + (BLOCKSIZE * 0) + threadRow * K + threadCol])
      : "memory"
    );
  
    asm volatile(
      "cp.async.ca.shared.global [%0], [%1], 4, 4;\n"
      :
      : "r"(static_cast<std::uint32_t>(__cvta_generic_to_shared(&Bs[0][threadRow][threadCol]))),
        "l"(&B[(cCol * BLOCKSIZE) + (BLOCKSIZE * N * 0) + threadRow * N + threadCol])
      : "memory"
    );
  
    // pipe.producer_commit();
    asm volatile(
        "cp.async.commit_group;\n"
    );
  
    asm volatile(
      "cp.async.ca.shared.global [%0], [%1], 4, 4;\n"
      :
      : "r"(static_cast<std::uint32_t>(__cvta_generic_to_shared(&As[1][threadRow][threadCol]))),
        "l"(&A[(cRow * BLOCKSIZE * K) + (BLOCKSIZE * 1) + threadRow * K + threadCol])
      : "memory"
    );
  
    asm volatile(
      "cp.async.ca.shared.global [%0], [%1], 4, 4;\n"
      :
      : "r"(static_cast<std::uint32_t>(__cvta_generic_to_shared(&Bs[1][threadRow][threadCol]))),
        "l"(&B[(cCol * BLOCKSIZE) + (BLOCKSIZE * N * 1) + threadRow * N + threadCol])
      : "memory"
    );
  
    // pipe.producer_commit();
    asm volatile(
        "cp.async.commit_group;\n"
    );
  
  
    for(size_t compute_batch = 0;compute_batch < batch_sz;compute_batch++){
      stage = compute_batch % 2;
      asm volatile(
        "cp.async.wait_group 1;\n"
      );
      // pipe.consumer_wait();
      // printf("A[%d, %d] => %f\n", threadRow, threadCol, As[stage][threadRow][threadCol]);
      // printf("B[%d, %d] => %f\n", threadRow, threadCol, Bs[stage][threadRow][threadCol]);
  
      __syncthreads();
      tmp += compute(As[stage], Bs[stage], threadRow, threadCol);
      __syncthreads();
      // pipe.consumer_release();
  
      if(2 + compute_batch < batch_sz){
        // cuda::memcpy_async(thread, &As[stage][threadRow][threadCol], &A[threadRow * K + threadCol], sizeof(float), pipe);
        // cuda::memcpy_async(thread, &Bs[stage][threadRow][threadCol], &B[threadRow * K + threadCol], sizeof(float), pipe);
  
        asm volatile(
          "cp.async.ca.shared.global [%0], [%1], 4, 4;\n"
          :
          : "r"(static_cast<std::uint32_t>(__cvta_generic_to_shared(&As[stage][threadRow][threadCol]))),
            "l"(&A[(cRow * BLOCKSIZE * K) + (BLOCKSIZE * (2 + compute_batch)) + threadRow * K + threadCol])
          : "memory"
        );
  
        asm volatile(
          "cp.async.ca.shared.global [%0], [%1], 4, 4;\n"
          :
          : "r"(static_cast<std::uint32_t>(__cvta_generic_to_shared(&Bs[stage][threadRow][threadCol]))),
            "l"(&B[(cCol * BLOCKSIZE) + (BLOCKSIZE * N * (2 + compute_batch)) + threadRow * N + threadCol])
          : "memory"
        );
  
        // pipe.producer_commit();
        asm volatile(
          "cp.async.commit_group;\n"
        );
      }
    }
    C[threadRow * N + threadCol] = tmp;
}  

