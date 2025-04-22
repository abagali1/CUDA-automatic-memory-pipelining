#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <fstream>
#include <iostream>
#include <iomanip>
#include <vector>

#include <time.h>
#include <unistd.h>
#include <sys/time.h>

#include <cuda_runtime.h>

#define CEIL_DIV(M, N) (((M) + (N)-1) / (N))
#define cudaCheck(err) (cudaCheckf(err, __FILE__, __LINE__))

extern "C" {
  extern unsigned char kernel_fatbin[];
  extern unsigned int kernel_fatbin_len;
}

const std::string errLogFile = "matrixValidationFailure.txt";
float get_sec() {
  struct timeval time;
  gettimeofday(&time, NULL);
  return (1e6 * time.tv_sec + time.tv_usec);
}

float cpu_elapsed_time(float &beg, float &end) { return 1.0e-6 * (end - beg); }

void cudaCheckf(cudaError_t error, const char *file, int line) {
  if (error != cudaSuccess) {
    printf("[CUDA ERROR] at file %s:%d:\n%s\n", file, line,
           cudaGetErrorString(error));
    exit(EXIT_FAILURE);
  }
};

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

void range_init_matrix(float *mat, int N) {
  for (int i = 0; i < N; i++) {
    mat[i] = i;
  }
}

void zero_init_matrix(float *mat, int N) {
  for (int i = 0; i < N; i++) {
    mat[i] = 0.0;
  }
}

void copy_matrix(const float *src, float *dest, int N) {
  int i;
  for (i = 0; src + i && dest + i && i < N; i++)
    *(dest + i) = *(src + i);
  if (i != N)
    printf("copy failed at %d while there are %d elements in total.\n", i, N);
}

void print_matrix(const float *A, int M, int N, std::ofstream &fs) {
  int i;
  fs << std::setprecision(2)
     << std::fixed; // Set floating-point precision and fixed notation
  fs << "[";
  for (i = 0; i < M * N; i++) {
    if ((i + 1) % N == 0)
      fs << std::setw(5) << A[i]; // Set field width and write the value
    else
      fs << std::setw(5) << A[i] << ", ";
    if ((i + 1) % N == 0) {
      if (i + 1 < M * N)
        fs << ";\n";
    }
  }
  fs << "]\n";
}

bool verify_matrix(float *matRef, float *matOut, int N) {
  double diff = 0.0;
  int i;
  for (i = 0; i < N; i++) {
    diff = std::fabs(matRef[i] - matOut[i]);
    if (diff > 0.015) {
      printf("Divergence! Should %lf, Is %lff (Diff %lff) at %d\n",
             matRef[i], matOut[i], diff, i);
      return false;
    }
  }
  return true;
}

int div_ceil(int numerator, int denominator) {
  std::div_t res = std::div(numerator, denominator);
  return res.rem ? (res.quot + 1) : res.quot;
}

extern "C" __global__ void sgemm_naive(int M, int N, int K, float alpha, const float *A, const float *B, float beta, float *C);
extern "C" __global__ void sgemm_global_mem_coalesce(int M, int N, int K, float alpha, const float *A, const float *B, float beta, float *C);
extern "C" __global__ void sgemm_shared_mem_block(int M, int N, int K, float alpha, const float *A, const float *B, float beta, float *C);
extern "C" __global__ void sgemm_shared_mem_block_async(int M, int N, int K, float alpha, const float *A, const float *B, float beta, float *C);
extern "C" __global__ void sgemm_shared_mem_block_async_overlap(int M, int N, int K, float alpha, const float *A, const float *B, float beta, float *C);


void run_sgemm_naive(int M, int N, int K, float alpha, float *A, float *B, float beta, float *C) {
  dim3 gridDim(CEIL_DIV(M, 32), CEIL_DIV(N, 32));
  dim3 blockDim(32, 32);
  sgemm_naive<<<gridDim, blockDim>>>(M, N, K, alpha, A, B, beta, C);
}
  
void run_sgemm_coalesce(int M, int N, int K, float alpha, float *A, float *B,
       float beta, float *C) {
  dim3 gridDim(CEIL_DIV(M, 32), CEIL_DIV(N, 32));
  dim3 blockDim(32, 32);
  sgemm_global_mem_coalesce<<<gridDim, blockDim>>>(M, N, K, alpha, A, B, beta, C);
}
  
void run_sgemm_shared_mem_block(int M, int N, int K, float alpha, float *A,
               float *B, float beta, float *C) {
  dim3 gridDim(CEIL_DIV(M, 32), CEIL_DIV(N, 32));
  dim3 blockDim(32, 32);
  // L1 cache becomes useless, since we access GMEM only via SMEM, so we carve
  // out all of L1 to SMEM. This doesn't currently make a difference, since
  // occupancy is limited by reg and thread count, but it's good to do anyway.
  cudaFuncSetAttribute(sgemm_shared_mem_block,
      cudaFuncAttributePreferredSharedMemoryCarveout,
      cudaSharedmemCarveoutMaxShared);
  sgemm_shared_mem_block<<<gridDim, blockDim>>>(M, N, K, alpha, A, B, beta, C);
}
  
void run_sgemm_shared_mem_block_async(int M, int N, int K, float alpha, float *A, float *B, float beta, float *C){
  dim3 gridDim(CEIL_DIV(M, 32), CEIL_DIV(N, 32));
  dim3 blockDim(32, 32);
  
  sgemm_shared_mem_block_async<<<gridDim, blockDim>>>(M, N, K, alpha, A, B, beta, C);
}
  
void run_sgemm_shared_mem_block_async_overlap(int M, int N, int K, float alpha, float *A, float *B, float beta, float *C){
  dim3 gridDim(CEIL_DIV(M, 32), CEIL_DIV(N, 32));
  dim3 blockDim(32, 32);
  // L1 cache becomes useless, since we access GMEM only via SMEM, so we carve
  // out all of L1 to SMEM. This doesn't currently make a difference, since
  // occupancy is limited by reg and thread count, but it's good to do anyway.
  cudaFuncSetAttribute(sgemm_shared_mem_block,
      cudaFuncAttributePreferredSharedMemoryCarveout,
      cudaSharedmemCarveoutMaxShared);
  sgemm_shared_mem_block_async_overlap<<<gridDim, blockDim>>>(M, N, K, alpha, A, B, beta, C);
}


void run_kernel(int kernel_num, int M, int N, int K, float alpha, float *A,
                float *B, float beta, float *C) {
  switch (kernel_num) {
  case 0:
    run_sgemm_naive(M, N, K, alpha, A, B, beta, C);
    break;
  case 1:
    run_sgemm_coalesce(M, N, K, alpha, A, B, beta, C);
    break;
  case 2:
    run_sgemm_shared_mem_block(M, N, K, alpha, A, B, beta, C);
    break;
  case 3:
    run_sgemm_shared_mem_block_async(M, N, K, alpha, A, B, beta, C);
    break;
  case 4:
    run_sgemm_shared_mem_block_async_overlap(M, N, K, alpha, A, B, beta, C);
    break;
  default:
    std::cout << "BAD: " << kernel_num << std::endl;
    throw std::invalid_argument("Unknown kernel number");
  }
}

void dump_mat(const std::string fname, const float *arr, const size_t size){
  FILE *f = fopen(fname.c_str(), "w");
  for(int i=0;i<size;i++){
    for(int j=0;j<size;j++){
      fprintf(f, "%lf ", arr[i * size + j]);
    }
    fprintf(f, "\n");
  }
  fclose(f);
}

int main(int argc, char **argv) {
  if (argc != 2) {
    std::cerr << "Please select a kernel (range 0 - 12, 0 for NVIDIA cuBLAS)"
              << std::endl;
    exit(EXIT_FAILURE);
  }

  // get kernel number
  int kernel_num = std::stoi(argv[1]);
  if (kernel_num < 0 || kernel_num > 12) {
    std::cerr << "Please enter a valid kernel number (0-12)" << std::endl;
    exit(EXIT_FAILURE);
  }

  // get environment variable for device
  int deviceIdx = 0;
  if (getenv("DEVICE") != NULL) {
    deviceIdx = atoi(getenv("DEVICE"));
  }
  cudaCheck(cudaSetDevice(deviceIdx));

  printf("Running kernel %d on device %d.\n", kernel_num, deviceIdx);

  // print some device info
  // CudaDeviceInfo();

  // Using cudaEvent for gpu stream timing, cudaEvent is equivalent to
  // publishing event tasks in the target stream
  float elapsed_time;
  cudaEvent_t beg, end;
  cudaEventCreate(&beg);
  cudaEventCreate(&end);

  // cuBLAS FLOPs ceiling is reached at 8192
  std::vector<int> SIZE = {64, 128, 256, 512, 1024, 2048, 4096, 8192};// 16384};

  long m, n, k, max_size;
  max_size = SIZE[SIZE.size() - 1];
  std::cout << "Max size: " << max_size << std::endl;

  float alpha = 1.0f, beta = 1.0f; // GEMM input parameters, C=α*AB+β*C

  float *A = nullptr, *B = nullptr, *C = nullptr,
        *C_ref = nullptr; // host matrices
  float *dA = nullptr, *dB = nullptr, *dC = nullptr,
        *dC_ref = nullptr; // device matrices

  A = (float *)malloc(sizeof(float) * max_size * max_size);
  B = (float *)malloc(sizeof(float) * max_size * max_size);
  C = (float *)malloc(sizeof(float) * max_size * max_size);
  C_ref = (float*)malloc(sizeof(float) * max_size * max_size);

  randomize_matrix(A, max_size * max_size);
  randomize_matrix(B, max_size * max_size);

  for(int i=0;i<max_size*max_size;i++){
    C[i] = 0.0f;
    C_ref[i] = 0.0f;
  }

  cudaCheck(cudaMalloc((void **)&dA, sizeof(float) * max_size * max_size));
  cudaCheck(cudaMalloc((void **)&dB, sizeof(float) * max_size * max_size));
  cudaCheck(cudaMalloc((void **)&dC, sizeof(float) * max_size * max_size));
  cudaCheck(cudaMalloc((void **)&dC_ref, sizeof(float) * max_size * max_size));

  cudaCheck(cudaMemcpy(dA, A, sizeof(float) * max_size * max_size,
                       cudaMemcpyHostToDevice));
  cudaCheck(cudaMemcpy(dB, B, sizeof(float) * max_size * max_size,
                       cudaMemcpyHostToDevice));
  cudaCheck(cudaMemcpy(dC, C, sizeof(float) * max_size * max_size,
                       cudaMemcpyHostToDevice));
  cudaCheck(cudaMemcpy(dC_ref, C, sizeof(float) * max_size * max_size,
                       cudaMemcpyHostToDevice));

  int repeat_times = 50;
  for (int size : SIZE) {
    m = n = k = size;

    std::cout << "dimensions(m=n=k) " << m << ", alpha: " << alpha
              << ", beta: " << beta << std::endl;
    // Verify the correctness of the calculation, and execute it once before the
    // kernel function timing to avoid cold start errors
    if (kernel_num != 0) {
      run_kernel(0, m, n, k, alpha, dA, dB, beta, dC_ref); // Executes the kernel, modifies the result matrix
      run_kernel(kernel_num, m, n, k, alpha, dA, dB, beta, dC); // Executes the kernel, modifies the result matrix

      cudaCheck(cudaDeviceSynchronize());
      cudaCheck(cudaGetLastError()); // Check for async errors during kernel run
      cudaMemcpy(C, dC, sizeof(float) * m * n, cudaMemcpyDeviceToHost);
      cudaMemcpy(C_ref, dC_ref, sizeof(float) * m * n, cudaMemcpyDeviceToHost);

      if (m < 128) {
          std::cout << " Logging dummy check output into " << errLogFile << "\n";
          std::ofstream fs;
          fs.open(errLogFile);
          fs << "A:\n";
          print_matrix(A, m, n, fs);
          fs << "B:\n";
          print_matrix(B, m, n, fs);
          fs << "C:\n";
          print_matrix(C, m, n, fs);
          fs << "Should:\n";
          print_matrix(C_ref, m, n, fs);
      }
      if (!verify_matrix(C_ref, C, m * n)) {
        std::cout
            << "Failed to pass the correctness verification"
            << std::endl;
        exit(EXIT_FAILURE);
      }
    }

    cudaEventRecord(beg);
    for (int j = 0; j < repeat_times; j++) {
      // We don't reset dC between runs to save time
      run_kernel(kernel_num, m, n, k, alpha, dA, dB, beta, dC);
    }
    cudaEventRecord(end);
    cudaEventSynchronize(beg);
    cudaEventSynchronize(end);
    cudaEventElapsedTime(&elapsed_time, beg, end);
    elapsed_time /= 1000.; // Convert to seconds

    long flops = 2 * m * n * k;
    printf(
        "Average elapsed time: (%7.6f) s, performance: (%7.1f) GFLOPS. size: "
        "(%ld).\n",
        elapsed_time / repeat_times,
        (repeat_times * flops * 1e-9) / elapsed_time, m);
    fflush(stdout);
    // make dC and dC_ref equal again (we modified dC while calling our kernel
    // for benchmarking)
    cudaCheck(cudaMemcpy(dC, dC_ref, sizeof(float) * m * n,
                         cudaMemcpyDeviceToDevice));
  }

  // Free up CPU and GPU space
  free(A);
  free(B);
  free(C);
  free(C_ref);
  cudaFree(dA);
  cudaFree(dB);
  cudaFree(dC);
  cudaFree(dC_ref);

  return 0;
};