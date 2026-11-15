#!/usr/bin/env bash
set -e

cleanup() {
    echo -e "\n[*] Stopping inference and restoring desktop..."
    docker compose --profile llama stop llama-server > /dev/null 2>&1 || true
    sudo systemctl isolate graphical.target
    exit 0
}
trap cleanup INT TERM EXIT

echo "[1/4] Freeing VRAM: isolating multi-user target (stopping desktop)..."
sudo systemctl isolate multi-user.target
sleep 1

echo "[2/4] Kernel tuning: dropping caches & setting performance governor..."
sudo sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
sudo cpupower frequency-set -g performance > /dev/null 2>&1 || true

echo "[3/4] Launching Docker container (monitoring stack is not touched)..."
# --wait: block until the model is actually loaded (healthcheck), not just started
docker compose --profile llama up -d --wait llama-server

echo "[4/4] Attaching to live logs (Press Ctrl+C to exit and restore GUI):"
docker logs -f llama-qwen27b
