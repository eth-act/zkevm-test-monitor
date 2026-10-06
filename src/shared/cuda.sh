#!/bin/bash
# cuda.sh - CUDA runtime lookup, sourced by src/run-isa-tests.sh and
# src/run-eth-act-standards-tests.sh.

# add_sp1_cuda_runtime — put a CUDA 12 runtime on LD_LIBRARY_PATH for SP1's GPU
# prover. sp1-perf's CUDA prover spawns the host-native sp1-gpu-server, which
# needs libcudart.so.12. The host /opt/cuda may be absent, so look for a
# directory that provides it (SP1_CUDA_LIB overrides the search). Returns 1
# when there is none.
add_sp1_cuda_runtime() {
  local CUDA_LIB="${SP1_CUDA_LIB:-}"
  if [ -z "$CUDA_LIB" ]; then
    for d in /usr/local/cuda/lib64 /opt/cuda/lib64 /usr/local/cuda-12/lib64 \
             /usr/local/cuda-12.8/lib64 /usr/local/lib/ollama/cuda_v12; do
      if ls "$d"/libcudart.so.12* >/dev/null 2>&1; then CUDA_LIB="$d"; break; fi
    done
  fi
  if [ -z "$CUDA_LIB" ]; then
    echo "  No libcudart.so.12 found for sp1-gpu-server. Set SP1_CUDA_LIB=<dir>."
    return 1
  fi
  export LD_LIBRARY_PATH="${CUDA_LIB}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  echo "  CUDA runtime for sp1-gpu-server: $CUDA_LIB"
}
