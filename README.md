# 🚀 High-Performance LLM Serving on AMD ROCm (RDNA2 / RX 6800 XT)

[![Docker](https://img.shields.io/badge/Container-Docker%20Compose-blue?logo=docker)](https://www.docker.com/)
[![ROCm](https://img.shields.io/badge/AMD-ROCm%2010.3-red?logo=amd)](https://rocm.docs.amd.com/)
[![llama.cpp](https://img.shields.io/badge/Inference-llama.cpp%20server-green)](https://github.com/ggml-org/llama.cpp)
[![Model](https://img.shields.io/badge/Model-Qwen3.8--27B-purple)]()

A production-grade Docker Compose blueprint for serving **Qwen 3.8 27B** on consumer AMD RDNA2 GPUs (**Radeon RX 6800 XT 16GB**) using official upstream `llama.cpp` ROCm builds.

Featuring native **Multi-Token Prediction (MTP)**, **48k context** via quantized KV-cache (`q4_0`), CPU-offloaded vision projector (`mmproj`), and headless VRAM optimization.

---

## 📊 Real-World Benchmarks (No Cherry-Picking)

Tested on **Qwen 3.8 27B UD-IQ4_XS** under full real-world load (**20,000+ token context**):

| Metric | GUI Mode (Active Desktop) | Headless Mode (TTY / No GUI) | Gain / Delta |
| :--- | :--- | :--- | :--- |
| **VRAM Footprint** | ~15.7 GB | **14.99 GB** | **~750–800 MB freed** |
| **Prompt Eval (Prefill)** | 399.88 t/s (18.6k tokens) | **416.50 t/s (20.7k tokens)** | **+16.6 t/s** |
| **Generation (at 21k context)** | 26.29 t/s | **27.77 t/s** | **+1.5 t/s** |
| **Short Context Generation** | 38.77 t/s | **~40.0 t/s** | - |
| **MTP Acceptance Rate** | 78.9% (mean len: 2.27) | **80.2% (mean len: 2.29)** | **Solid ~80% hit rate** |

> **Key Architectural Takeaway:**  
> In hybrid attention architectures like Qwen (Gated DeltaNet / SSM with `full_attention_interval = 4`), saving **~800 MB of VRAM** via headless mode provides an additional **+60,000 to +80,000 tokens of Q4 context headroom** because 3 out of 4 layers maintain fixed $O(1)$ recurrent state.

---

## 🛠️ Key Architectural Decisions

1. **RDNA2 Hardware Passthrough:**
   Overcoming ROCm's lack of out-of-the-box consumer GPU support via `HSA_OVERRIDE_GFX_VERSION=10.3.0` and direct `/dev/kfd` + `/dev/dri` device mapping with host numeric GIDs.
2. **Offloading Multimodal Projector to Host RAM:**
   Using `--no-mmproj-offload` / `LLAMA_ARG_MMPROJ_OFFLOAD=false` keeps the ~1.8 GB BF16 vision model in 32GB system DDR4 RAM, reserving 100% of the 16GB VRAM for 27B weights, MTP context, and 48k KV-cache.
3. **Native Multi-Token Prediction (MTP):**
   Activating the pre-baked layer 64 `nextn` tensors via `--spec-type draft-mtp` yields an **80% acceptance rate**, accelerating generation from ~20 t/s to **27–38+ t/s** without requiring a separate draft model.
4. **Balanced Server-Side Reasoning:**
   Configured `--reasoning-effort medium` and `--no-reasoning-preserve` to ensure lightweight Android/Web clients get balanced step-by-step deductions without filling the 48k context with stale thoughts.

---

## 🚀 Quickstart

1. Clone repository:
   ```bash
   git clone git@github.com:selfcortex/rocm-qwen27b-mtp-docker.git
   cd rocm-qwen27b-mtp-docker

    Adjust your model directory path in docker-compose.yml:
    code Yaml

    volumes:
      - /path/to/your/models:/models:ro

    Start inference server:
    code Bash

    docker compose up -d

    Or run with automatic VRAM optimization:
    code Bash

    ./run.sh


