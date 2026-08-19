#!/usr/bin/env bash
# Measures throughput and VRAM for a set of models on the Arc B580 (ai-platform namespace,
# homelab cluster). Output is a markdown table. Port of jotunheim/hack/bench-ollama.sh
# (otter/7900 XTX) to this cluster's Ollama.
#
#   hack/bench-ollama.sh qwen2.5-coder:7b llama3.1:8b
#
# The B580's Ollama Service is ClusterIP-only, with no LAN hostname and no bearer token
# (unlike otter's reverse-proxied endpoint, see ADR-0003) -- it's reachable only from inside
# the cluster. This manages its own `kubectl port-forward` for the run by default; pass
# OLLAMA_URL to skip that and hit an endpoint you've already made reachable yourself.
#
# There's no rocm-smi equivalent proven on this passed-through Battlemage VM, and no SSH to
# the Talos node either (ADR-0002 already documents degraded GPU telemetry there: no
# MEI/GSC). So unlike the otter script, there's no independent whole-GPU VRAM column here --
# "on GPU" and "VRAM (ollama)" below come from Ollama's own /api/ps accounting, same source
# the otter script also uses for those two columns.
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <model> [model...]" >&2
  echo "example: $0 qwen2.5-coder:7b llama3.1:8b" >&2
  exit 1
fi

NAMESPACE="${NAMESPACE:-ai-platform}"
SERVICE="${SERVICE:-ollama}"
LOCAL_PORT="${LOCAL_PORT:-11434}"
RUNS="${RUNS:-3}"
PROMPT="${PROMPT:-Write a Go function that merges two sorted integer slices into one sorted slice, with a short explanation.}"
NUM_PREDICT="${NUM_PREDICT:-512}"

kubectl_cmd=(kubectl)
[ -n "${KUBECTL_CONTEXT:-}" ] && kubectl_cmd+=(--context "$KUBECTL_CONTEXT")

# Presence, not value, is the switch: an explicitly set OLLAMA_URL (even empty) means the
# caller already made the endpoint reachable and manages that themselves.
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

echo "| model | weights | load s | tok/s | on GPU | VRAM (ollama) |"
echo "|---|---|---|---|---|---|"

for model in "$@"; do
  api -X POST "${OLLAMA_URL}/api/pull" -d "{\"model\":\"${model}\"}" >/dev/null

  best_tps=0 load_s=0
  for _ in $(seq "$RUNS"); do
    resp="$(api -X POST "${OLLAMA_URL}/api/generate" -d "$(python3 -c '
import json,sys
model, prompt, npredict = sys.argv[1], sys.argv[2], int(sys.argv[3])
print(json.dumps({"model": model, "prompt": prompt,
                  "stream": False, "options": {"num_predict": npredict}}))
' "$model" "$PROMPT" "$NUM_PREDICT")")"

    read -r tps ld <<<"$(python3 -c '
import json,sys
d = json.load(sys.stdin)
ev, dur = d.get("eval_count", 0), d.get("eval_duration", 0)
print("%.1f %.1f" % (ev / (dur / 1e9) if dur else 0, d.get("load_duration", 0) / 1e9))
' <<<"$resp")"
    awk "BEGIN{exit !($tps > $best_tps)}" && best_tps="$tps"
    load_s="$ld"
  done

  # size_vram below total size means layers stayed on the CPU, which reads as poor tok/s
  # rather than an error.
  onstats="$(api "${OLLAMA_URL}/api/ps" | python3 -c '
import json,sys
m = sys.argv[1]
for x in json.load(sys.stdin).get("models", []):
    if m in (x.get("name"), x.get("model")):
        tot, vram = x.get("size", 0), x.get("size_vram", 0)
        print("%.1f %d" % (vram / 1e9, round(100 * vram / tot) if tot else 0)); break
else:
    print("0.0 0")
' "$model")"
  read -r vram_gb on_gpu_pct <<<"$onstats"

  size="$(api "${OLLAMA_URL}/api/tags" | python3 -c '
import json,sys
m = sys.argv[1]
for x in json.load(sys.stdin)["models"]:
    if m in (x["name"], x["model"]):
        print("%.1f GB" % (x["size"] / 1e9)); break
else:
    print("?")
' "$model")"

  echo "| ${model} | ${size} | ${load_s} | ${best_tps} | ${on_gpu_pct}% | ${vram_gb} GB |"
done

echo
echo "Unloading, then confirming release (OLLAMA_KEEP_ALIVE governs this otherwise)."
for m in "$@"; do
  api -X POST "${OLLAMA_URL}/api/generate" -d "{\"model\":\"${m}\",\"keep_alive\":0}" >/dev/null || true
done
sleep 5
remaining="$(api "${OLLAMA_URL}/api/ps" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("models", [])))')"
echo "Models still resident after unload: ${remaining}"
