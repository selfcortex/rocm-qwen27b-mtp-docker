# 🚀 Qwen 3.8 27B on AMD ROCm (RDNA2 / RX 6800 XT) + Monitoring

[![Docker](https://img.shields.io/badge/Container-Docker%20Compose-blue?logo=docker)](https://www.docker.com/)
[![ROCm](https://img.shields.io/badge/AMD-ROCm%207.2.1-red?logo=amd)](https://rocm.docs.amd.com/)
[![llama.cpp](https://img.shields.io/badge/Inference-llama.cpp%20server-green)](https://github.com/ggml-org/llama.cpp)
[![Model](https://img.shields.io/badge/Model-Qwen3.8--27B-purple)]()
[![Prometheus](https://img.shields.io/badge/Monitoring-Prometheus%20+%20Grafana-orange?logo=prometheus)](https://prometheus.io/)

Serving **Qwen 3.8 27B** on a consumer AMD RDNA2 GPU (**Radeon RX 6800 XT 16GB**) with official upstream `llama.cpp` ROCm builds, plus a fully local monitoring stack (Prometheus, node-exporter, Grafana) that tracks the host and the GPU while the model runs.

Featuring native **Multi-Token Prediction (MTP)**, an **80k context** (81920 tokens, `-c 81920` in `docker-compose.yml`) via quantized KV-cache (`q4_0`), CPU-offloaded vision projector (`mmproj`), headless VRAM optimization, and a **GPU monitoring pipeline** (temperature, power, VRAM, busy %) read directly from the kernel.

---

## 📊 Real-World Benchmarks (No Cherry-Picking)

Tested on **Qwen 3.8 27B UD-IQ4_XS** under full real-world load (**20,000+ token context**):

| Metric | GUI Mode (Active Desktop) | Headless Mode (TTY / No GUI) | Gain / Delta |
| :--- | :--- | :--- | :--- |
| **VRAM Footprint** | ~15.7 GB | **14.99 GB** | **~750–800 MB freed** |
| **Prompt Eval (Prefill)** | 399.88 t/s (18.6k tokens) | **416.50 t/s** (20.7k tokens) | **+16.6 t/s** |
| **Generation (at 21k context)** | 26.29 t/s | **27.77 t/s** | **+1.5 t/s** |
| **Short Context Generation** | 38.77 t/s | **~40.0 t/s** | - |
| **MTP Acceptance Rate** | 78.9% (mean len: 2.27) | **80.2%** (mean len: 2.29) | **Solid ~80% hit rate** |

> **Key Architectural Takeaway:**
> In hybrid attention architectures like Qwen (Gated DeltaNet / SSM with `full_attention_interval = 4`), saving **~800 MB of VRAM** via headless mode provides an additional **+60,000 to +80,000 tokens of Q4 context headroom** because 3 out of 4 layers maintain fixed $O(1)$ recurrent state.

---

## 🧠 Model

The model files are **not** in this repository. Place them anywhere on the host, set their absolute paths in `.env`, and verify them once:

| File | Role | SHA-256 |
| :--- | :--- | :--- |
| `Qwen3.8-27B-UD-IQ4_XS.gguf` (~13.2 GiB) | Qwen 3.8 27B, UD-IQ4_XS quantization | `40fac4050e940397dbf13087afd50f4734a11805bf9d65ef8ddd7483470e6199` |
| `mmproj-model-bf16.gguf` (~888 MiB) | vision projector (BF16, kept in RAM) | `c9a09064683620bea3d3bfed5d4462e1a97a7d2fff7e5045d6862a0a85eeb5b5` |

```bash
sha256sum /path/to/Qwen3.8-27B-UD-IQ4_XS.gguf   # must match the table above
```

The container mounts only these two files read-only — nothing else from the host disk is visible to it. Check the license of your model source; this repo makes no claim about model licensing.

## 🛠️ Key Architectural Decisions

1. **RDNA2 Hardware Passthrough:**
   Overcoming ROCm's lack of out-of-the-box consumer GPU support via `HSA_OVERRIDE_GFX_VERSION=10.3.0` and direct `/dev/kfd` + `/dev/dri` device mapping with host group IDs (from `.env`).
2. **Offloading Multimodal Projector to Host RAM:**
   Using `--no-mmproj-offload` keeps the ~1.8 GB BF16 vision model in 32GB system DDR4 RAM, reserving 100% of the 16GB VRAM for 27B weights, MTP context, and the 80k KV-cache.
3. **Native Multi-Token Prediction (MTP):**
   Activating the pre-baked layer 64 `nextn` tensors via `--spec-type draft-mtp` yields an **~80% acceptance rate**, accelerating generation from ~20 t/s to **27–40+ t/s** without needing a separate draft model.
4. **Pinned Image Digest:**
   The llama.cpp image is pinned by **digest**, not a floating tag, so the serving and metrics behavior is reproducible and the metric names in the dashboards stay stable.

---

## 📡 Monitoring Stack

```
Host (CachyOS)
└─ Docker Compose (one project)
   ├─ llama-server    :8080   profile "llama", GPU /dev/kfd+/dev/dri, --metrics  (managed by run.sh)
   ├─ node-exporter   (int.)  CPU/RAM/disk + AMD GPU via /sys (drm + hwmon collectors)
   ├─ prometheus      (int.)  scrapes node-exporter + llama-server, 2d retention
   └─ grafana         :3000   provisioning from files, bound to LAN_IP only
```

- **llama-server** is its own compose **profile** (`llama`): `./run.sh` starts and stops only it. The monitoring stack keeps running the whole time — you see GPU and inference metrics *while* the model is running.
- **GPU metrics without special exporters.** The official AMD Device Metrics Exporter only supports Instinct cards, so node-exporter reads `amdgpu` straight from the kernel: `/sys/class/drm/card*/device` (busy %, VRAM) and `hwmon` (temperature, power, fan, clock). Read-only mounts, `pid: host`.
- **llama target via `file_sd`** (`prometheus/targets/llama.yml`): the server runs on the host's network, so Prometheus reaches it through `host.docker.internal` (mapped to `host-gateway`). Switching to an in-compose server later is a one-line change.
- **Only Grafana is published**, and only on the LAN interface (`LAN_IP:3000`). Prometheus and node-exporter have no published ports at all.
- **Network traffic counters are intentionally not collected.** `/proc/net` is per network namespace: read from inside the container it describes the container's `eth0`, not the host NICs. The `netdev`/`netstat`/`sockstat` collectors are therefore disabled. (The `netclass` interface-metadata collector reads the host's `/sys` mount and does report host interfaces — that part is accurate.) CPU/RAM/disk/GPU are the point of this stack.
- **Dashboards as code**: datasource and dashboards are provisioned from files — a clean `docker compose up -d` on a fresh machine is enough.

## 🚀 Quickstart

Prerequisites (host, one time):

- **Linux (tested on CachyOS) with the `amdgpu` kernel module** loaded (`lsmod | grep amdgpu`) and an RDNA2 GPU (tested on RX 6800 XT 16GB);
- **Docker Engine ≥ 24** with the `compose` plugin ≥ 2.24 (`docker compose version`);
- your user in the `video` and `render` groups (for `/dev/dri` / `/dev/kfd` access);
- the model files (see [Model](#-model)).

```bash
# 0. Clone
git clone https://github.com/selfcortex/rocm-qwen27b-mtp-docker.git
cd rocm-qwen27b-mtp-docker

# 1. Configure (one time)
make init          # copies .env.example -> .env and generates secrets/llama_api_key
# edit .env: LAN_IP, GRAFANA_PASSWORD, MODEL_FILE, MMPROJ_FILE,
#            VIDEO_GID/RENDER_GID (getent group video render)

# 2. Start monitoring (one time; survives reboots via restart: unless-stopped)
docker compose up -d
# or: make up

# 3. Open Grafana: http://<LAN_IP>:3000  (login: .env values)

# 4. Run an inference session (stops the desktop to free VRAM, starts the model)
./run.sh
# Ctrl+C stops the model and restores the desktop; monitoring keeps running
```

Useful targets while a session is active:

```bash
KEY=$(cat secrets/llama_api_key)
curl -s -H "X-Api-Key: $KEY" localhost:8080/metrics | head   # raw llama.cpp metrics
curl -s -H "Authorization: Bearer $KEY" localhost:8080/props  # server properties (auth required)
curl -s localhost:8080/health                                 # public, no key needed
docker compose ps                            # stack status
make logs                                    # monitoring logs
make check                                   # validate configs (compose + promtool)
```

OpenAI-compatible clients need the key too (`api_key: "$KEY"` in the SDK, or the `Authorization: Bearer $KEY` header).

## ⚙️ Configuration (`.env`)

| Variable | Default | Description |
| :--- | :--- | :--- |
| `LAN_IP` | — (required) | LAN address the Grafana port is bound to (not `0.0.0.0`) |
| `GRAFANA_USER` / `GRAFANA_PASSWORD` | `admin` / required | Grafana admin credentials |
| `MODEL_FILE` / `MMPROJ_FILE` | — (required) | Absolute host paths to the model and vision projector (see [Model](#-model)) |
| `VIDEO_GID` / `RENDER_GID` | — (required) | Host group IDs for `/dev/dri` / `/dev/kfd` (`getent group video render`) |
| `HSA_OVERRIDE_GFX_VERSION` | `10.3.0` | ROCm gfx override (default = RX 6800 XT / gfx1030) |

## 🔐 Security

- Secrets live only in `.env` (gitignored) and `secrets/` (gitignored); the repo ships `.env.example`.
- No published ports for Prometheus / node-exporter; Grafana bound to the LAN IP only.
- Anonymous access and self-service signup are disabled in Grafana.
- llama-server is protected by an API key: `--api-key-file secrets/llama_api_key` (generated by `make init`). Every route except `/health` and the embedded UI requires the key (`X-Api-Key` or `Authorization: Bearer`); CORS is pinned to `localhost`, so browser pages on other origins cannot reach it. The same key is mounted into Prometheus, and its `llama` job sends it via `authorization.credentials_file` (re-read on every scrape, so rotation needs no reload).
- Grafana telemetry and phone-home checks are disabled (`GF_ANALYTICS_*`, no Gravatar).
- Grafana speaks plain HTTP on the LAN: the admin password is sent unencrypted on login. Keep the LAN trusted, or put the optional Caddy+TLS reverse proxy in front.
- Next hardening stage: firewall rules for the LAN port, optional Caddy+TLS reverse proxy.

## 🧯 Troubleshooting

| Symptom | Fix |
| :--- | :--- |
| `:8080/metrics` returns 501 "start with --metrics" | The server is running without the flag — restart the session with the updated compose (`./run.sh`) |
| `llama` target is DOWN in Prometheus while the model runs | llama uses `network_mode: host` — make sure the prometheus container has `extra_hosts: host.docker.internal:host-gateway` |
| No GPU panels in Grafana | Check `docker logs llama-node-exporter`; the `drm`/`hwmon` collectors need the read-only `/sys` mount and a card under `/sys/class/drm` |
| Grafana won't bind | `LAN_IP` in `.env` must be an address actually present on the machine (`ip -br a`) |
| `make check` fails on rules | Rule files must pass `promtool check rules` — alert stage is not enabled yet, keep `rules/` empty |
| Changed `GRAFANA_PASSWORD` in `.env`, but the old password still works | The admin password is applied **only on first initialization** of the `grafana-data` volume. To change it: stop the stack, remove the volume (`docker volume rm ai-compose_grafana-data` — name may differ, see `docker volume ls`), start again and re-import the dashboard provisioning |

## 🗺️ Roadmap

- [ ] Alert rules + Alertmanager → Telegram (silences on planned model stop)
- [x] llama-server `--api-key` hardening
- [ ] Screenshots in this README

## 📁 Structure

```
.
├─ docker-compose.yml          # full stack (llama under profile "llama")
├─ run.sh                      # inference session: VRAM tuning + model + live logs
├─ Makefile                    # init / up / down / logs / check / session
├─ .env.example                # template for .env (gitignored)
├─ secrets/llama_api_key       # llama API key (generated by make init, gitignored)
├─ prometheus/
│  ├─ prometheus.yml           # scrape config, 2d retention
│  ├─ targets/llama.yml        # file_sd target for llama-server
│  └─ rules/                   # alert rules (next stage)
└─ grafana/
   ├─ provisioning/            # datasource + dashboard provider (as code)
   └─ dashboards/              # "llama.cpp + GPU" dashboard JSON
```
