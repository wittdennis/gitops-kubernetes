#!/usr/bin/env bash
# Finds where a model stops fitting as its context grows, on the Arc B580 (ai-platform
# namespace, homelab cluster). llama.cpp allocates the KV cache at load time, so a short
# prompt with a large num_ctx costs the same VRAM as a full one: the question is answered
# without having to generate a huge prompt. Port of jotunheim/hack/bench-context.sh
# (otter/7900 XTX) to this cluster's Ollama.
#
#   hack/bench-context.sh qwen2.5-coder:7b
#   CTX_LIST="4096 8192 16384" hack/bench-context.sh llama3.1:8b
#
# Watch the "on GPU" column: the first value below 100% is the ceiling, and the tok/s beside
# it shows what exceeding it costs. See bench-ollama.sh in this directory for why there's no
# whole-GPU VRAM column here (no rocm-smi equivalent, no SSH to the Talos node) and why this
# manages its own `kubectl port-forward` by default.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <model>" >&2
  exit 1
fi

model="$1"
NAMESPACE="${NAMESPACE:-ai-platform}"
SERVICE="${SERVICE:-ollama}"
LOCAL_PORT="${LOCAL_PORT:-11434}"
CTX_LIST="${CTX_LIST:-4096 8192 16384 32768 65536 131072}"
PROMPT="${PROMPT:-Write a Go function that merges two sorted integer slices.}"
NUM_PREDICT="${NUM_PREDICT:-128}"

kubectl_cmd=(kubectl)
[ -n "${KUBECTL_CONTEXT:-}" ] && kubectl_cmd+=(--context "$KUBECTL_CONTEXT")

if [ -n "${OLLAMA_URL+x}" ]; then
  manage_port_forward=0
else
  OLLAMA_URL="http://localhost:${LOCAL_PORT}"
  manage_port_forward=1
fi

api() { curl -sS --fail-with-body "$@"; }

pf_pid=""
cleanup() { [ -n "$pf_pid" ] && kill "$pf_pid" 2>/dev/null || true; }
trap cleanup EXIT

if [ "$manage_port_forward" -eq 1 ]; then
  "${kubectl_cmd[@]}" port-forward -n "$NAMESPACE" "svc/${SERVICE}" "${LOCAL_PORT}:11434" >/dev/null 2>&1 &
  pf_pid=$!
  ready=0
  for _ in $(seq 1 30); do
    if api "${OLLAMA_URL}/" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 0.5
  done
  [ "$ready" -eq 1 ] || { echo "port-forward to ${SERVICE}.${NAMESPACE} never became ready" >&2; exit 1; }
fi

unload() { api -X POST "${OLLAMA_URL}/api/generate" -d "{\"model\":\"${model}\",\"keep_alive\":0}" >/dev/null || true; }

# Ollama clamps num_ctx to this at load time rather than erroring, so anything requested
# above it silently re-tests the same ceiling under a different label.
native_ctx="$(api -X POST "${OLLAMA_URL}/api/show" -d "{\"model\":\"${model}\"}" | python3 -c '
import json,sys
d = json.load(sys.stdin).get("model_info", {})
for k, v in d.items():
    if k.endswith(".context_length"):
        print(v); break
else:
    print(0)
')"

echo "Model: ${model}"
if [ "$native_ctx" -gt 0 ]; then
  echo "Native context_length: ${native_ctx} (requests above this are clamped by Ollama, not actually tested)"
fi
echo
echo "| num_ctx | on GPU | VRAM (ollama) | tok/s |"
echo "|---|---|---|---|"

for ctx in $CTX_LIST; do
  if [ "$native_ctx" -gt 0 ] && [ "$ctx" -gt "$native_ctx" ]; then
    echo "| ${ctx} | clamped to ${native_ctx} | | |"
    continue
  fi

  # Reload for each value: the KV cache is sized once, when the model is loaded.
  unload
  sleep 3

  resp="$(api -X POST "${OLLAMA_URL}/api/generate" -d "$(python3 -c '
import json,sys
model, prompt, npredict, ctx = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
print(json.dumps({"model": model, "prompt": prompt, "stream": False,
                  "options": {"num_predict": npredict, "num_ctx": ctx}}))
' "$model" "$PROMPT" "$NUM_PREDICT" "$ctx")" || true)"

  if [ -z "$resp" ]; then
    echo "| ${ctx} | request failed | | |"
    continue
  fi

  tps="$(python3 -c '
import json,sys
d = json.load(sys.stdin)
ev, dur = d.get("eval_count", 0), d.get("eval_duration", 0)
print("%.1f" % (ev / (dur / 1e9) if dur else 0))
' <<<"$resp")"

  read -r vram_gb on_gpu_pct <<<"$(api "${OLLAMA_URL}/api/ps" | python3 -c '
import json,sys
m = sys.argv[1]
for x in json.load(sys.stdin).get("models", []):
    if m in (x.get("name"), x.get("model")):
        tot, vram = x.get("size", 0), x.get("size_vram", 0)
        print("%.1f %d" % (vram / 1e9, round(100 * vram / tot) if tot else 0)); break
else:
    print("0.0 0")
' "$model")"

  echo "| ${ctx} | ${on_gpu_pct}% | ${vram_gb} GB | ${tps} |"
done

unload
