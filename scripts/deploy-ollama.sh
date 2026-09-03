#!/usr/bin/env bash
# deploy-ollama.sh <your-model.gguf> [model-name] — deploy a fine-tuned embedding model as an Ollama service
# Bakes in this book's three incidents: num_batch 16384 / distinct naming against pull-overwrite / vector fingerprint verification.
set -euo pipefail
GGUF="${1:?usage: $0 <model.gguf> [model-name]}"
NAME="${2:-my-embed-ft}"   # distinct name (with -ft), never colliding with an official library name (incident #2)
[ -f "$GGUF" ] || { echo "FAIL: $GGUF does not exist"; exit 1; }
case "$NAME" in *-ft*|*-custom*|*-mine*) ;; *) echo "FAIL: model name must contain a -ft/-custom/-mine suffix (defends against silent ollama pull overwrite, incident #2)"; exit 1;; esac
command -v ollama >/dev/null || { echo "FAIL: ollama is required"; exit 1; }
curl -s -m 3 http://127.0.0.1:11434/api/tags >/dev/null || { echo "FAIL: Ollama is not running on 11434. Run ollama serve first"; exit 1; }
if ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$NAME"; then
  [ "${FORCE:-0}" = 1 ] || { echo "FAIL: model $NAME already exists. To confirm overwrite, rerun with FORCE=1"; exit 1; }
fi

say() { printf '\033[1m[deploy]\033[0m %s\n' "$*"; }

# ── 1. Modelfile (explicit num_batch = incident #1 mechanized; carry it along on every rebuild) ──
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
GGUF_ABS=$(cd "$(dirname "$GGUF")" && pwd)/$(basename "$GGUF")
cat > "$TMP/Modelfile" <<EOF
FROM "$GGUF_ABS"
PARAMETER num_batch 16384
EOF
say "Creating model $NAME (num_batch 16384 set explicitly)"
ollama create "$NAME" -f "$TMP/Modelfile"

# ── 2. Long-input assertion (2048+ tokens must not crash = incident #1 verification) ──
say "Long-input assertion (~4000 tokens; the default num_batch 2048 crashes with EOF)..."
python3 - "$NAME" <<'PY'
import json, sys, urllib.request
name = sys.argv[1]
long_text = "Machine learning is a branch of artificial intelligence. " * 300   # ~4000+ tokens
req = {"model": name, "input": long_text}
r = urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:11434/api/embed",
    json.dumps(req).encode(), {"Content-Type": "application/json"}), timeout=120)
d = json.load(r)
vec = d["embeddings"][0]
assert len(vec) > 0, "FATAL: empty vector"
print(f"  long input passed, dimensions={len(vec)}")
# ── 3. Vector fingerprint to disk (incident #3: content verification; used by the periodic canary check) ──
fp = [round(x, 6) for x in vec[:8]]
import os
fpdir = os.path.expanduser("~/.local/share/embed-canary"); os.makedirs(fpdir, exist_ok=True)
fpp = f"{fpdir}/{name}-fingerprint.json"
open(fpp, "w").write(json.dumps({"probe": "fixed", "fp8": fp}))
print(f"  vector fingerprint saved to {fpp} (persistent location; canary guard: periodically re-embed the same input and compare — drift = weights were overwritten)")
PY
say "✅ Deploy complete: POST 127.0.0.1:11434/api/embed model=$NAME"
say "Recommended: turn the fingerprint comparison into a scheduled job (canary guard, the long-term defense for incident #2)"
