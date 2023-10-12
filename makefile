# no implicit rules for any (default) suffixed file
.SUFFIXES:

SHELL:=/bin/bash
WORK_PATH:=$(PWD)
CUDA_PATH:=/usr/local/cuda-11.8
LLVM_PATH:=$(WORK_PATH)/llvm-project
LLVM_BUILD_PATH:=$(LLVM_PATH)/build
CBP_BUILD_PATH:=$(WORK_PATH)/build

CLANG:=$(LLVM_BUILD_PATH)/bin/clang++
OPT:=$(LLVM_BUILD_PATH)/bin/opt
LLVM_DIS:=$(LLVM_BUILD_PATH)/bin/llvm-dis
KERNEL_GEN:=$(CBP_BUILD_PATH)/compilation/kernelTranslator

# DO not use it for production
DEV_CFLAGS=-D__NO_USE_TLS__ -g -fPIC
DEV_LFLAGS=-L$(LLVM_BUILD_PATH)/lib \
           -Wl,-rpath,$(LLVM_BUILD_PATH)/lib \
           -Wl,-rpath,$(BUILD_PATH)/runtime \
           -Wl,-rpath,$(BUILD_PATH)/runtime/threadPool

all: build-cupbop

config-llvm:
	{ \
      echo "Configure for Native (X86) LLVM/Clang build..."; \
      mkdir -p $(LLVM_BUILD_PATH); \
      cd $(LLVM_BUILD_PATH); \
      rm -f CMakeCache.txt; \
      cmake ../llvm -G Ninja \
        -DLLVM_ENABLE_PROJECTS='clang;llvm;polly' \
        -DLLVM_TARGETS_TO_BUILD='X86;NVPTX' \
        -DBUILD_SHARED_LIBS=ON \
        -DLLVM_ENABLE_BACKTRACES=ON; \
    }

build-llvm:
	cd $(LLVM_BUILD_PATH) && echo "Building LLVM/Clang..." && ninja

config-cupbop: build-llvm
	{ \
      echo "Configure CuPBoP..."; \
      mkdir -p $(CBP_BUILD_PATH) && cd $(CBP_BUILD_PATH); \
      cmake .. -G Ninja \
        -DLLVM_CONFIG_PATH=$(LLVM_BUILD_PATH)/bin/llvm-config \
        -DCUDA_PATH=/usr/local/cuda-11.8 \
        -DCMAKE_CXX_FLAGS="$(DEV_CFLAGS)" \
        -DCMAKE_EXE_LINKER_FLAGS="$(DEV_LFLAGS)" \
        -DCMAKE_SHARED_LINKER_FLAGS="$(DEV_LFLAGS)" \
        -DCMAKE_BUILD_TYPE=Debug; \
    }

build-cupbop: config-cupbop
	cd $(CBP_BUILD_PATH) && echo "Building CuPBoP..." && ninja

$(KERNEL_GEN): build-cupbop

%-cuda-nvptx64-nvidia-cuda-sm_50.bc %.bc: %.cu | $(CLANG)
	{ \
	  echo "Compile CUDA source code to generate host/kernel .bc files"; \
	  cd $$(dirname $<); \
	  $(CLANG) -c -std=c++11 $$(basename $<) \
	      -I../.. -emit-llvm  $(TARGET_PLATFORM_CXX_FLAGS) \
	      --cuda-path=$(CUDA_PATH) --cuda-gpu-arch=sm_50 -L$(CUDA_PATH)/lib64; \
	}

%-kernel.bc: %-cuda-nvptx64-nvidia-cuda-sm_50.bc | $(KERNEL_GEN)
	{ \
	  echo "Translate CUDA kernel .bc files to X86"; \
	  $(KERNEL_GEN) $< $@; \
	}

%.ll: %.bc | $(LLVM_DIS)
	$(LLVM_DIS) $< -o $@

%.preopt.ll: %.ll | $(OPT)
	$(OPT) -S -polly-canonicalize $< -o $@

ir: examples/vecadd/vecadd-kernel.ll

scop: examples/vecadd/vecadd-kernel.preopt.ll
	$(OPT) -basic-aa -polly-ast -analyze $< -polly-process-unprofitable -polly-use-llvm-names

polly: examples/vecadd/vecadd-kernel.preopt.ll
	$(OPT) -polly-use-llvm-names -basic-aa -polly-scops -analyze $< -polly-process-unprofitable

deps: examples/vecadd/vecadd-kernel.preopt.ll
	$(OPT) -basic-aa -polly-use-llvm-names -polly-dependences -analyze $< -polly-process-unprofitable

clean:
	rm -f examples/vecadd/*.ll examples/vecadd/*.bc
