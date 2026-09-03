#!/usr/bin/env bash
# deploy-ollama.sh <你的模型.gguf> [模型名] — 把微调 embedding 产物部署为 Ollama 服务
# 内化本书三事故:num_batch 16384 / 独立命名防 pull 覆盖 / 向量指纹验证。
set -euo pipefail
GGUF="${1:?用法: $0 <model.gguf> [模型名]}"
NAME="${2:-my-embed-ft}"   # 独立命名(带 -ft),永不与官方库同名(事故 #2)
[ -f "$GGUF" ] || { echo "FAIL: $GGUF 不存在"; exit 1; }
case "$NAME" in *-ft*|*-custom*|*-mine*) ;; *) echo "FAIL: 模型名必须含 -ft/-custom/-mine 后缀(防 ollama pull 静默覆盖,事故 #2)"; exit 1;; esac
command -v ollama >/dev/null || { echo "FAIL: 需要 ollama"; exit 1; }
curl -s -m 3 http://127.0.0.1:11434/api/tags >/dev/null || { echo "FAIL: Ollama 服务未在 11434 运行。先 ollama serve"; exit 1; }
if ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$NAME"; then
  [ "${FORCE:-0}" = 1 ] || { echo "FAIL: 模型 $NAME 已存在。确认覆盖用 FORCE=1 重跑"; exit 1; }
fi

say() { printf '\033[1m[deploy]\033[0m %s\n' "$*"; }

# ── 1. Modelfile(num_batch 显式=事故 #1 的机器化,每次重建都带上) ──
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
GGUF_ABS=$(cd "$(dirname "$GGUF")" && pwd)/$(basename "$GGUF")
cat > "$TMP/Modelfile" <<EOF
FROM "$GGUF_ABS"
PARAMETER num_batch 16384
EOF
say "创建模型 $NAME(num_batch 16384 已显式)"
ollama create "$NAME" -f "$TMP/Modelfile"

# ── 2. 长输入断言(2048+ token 不崩=事故 #1 验证) ──
say "长输入断言(~4000 token,默认 num_batch 2048 会 EOF 崩)..."
python3 - "$NAME" <<'PY'
import json, sys, urllib.request
name = sys.argv[1]
long_text = "机器学习是人工智能的一个分支。" * 300   # ~4000+ token
req = {"model": name, "input": long_text}
r = urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:11434/api/embed",
    json.dumps(req).encode(), {"Content-Type": "application/json"}), timeout=120)
d = json.load(r)
vec = d["embeddings"][0]
assert len(vec) > 0, "FATAL: 空向量"
print(f"  长输入通过,维度={len(vec)}")
# ── 3. 向量指纹落盘(事故 #3:内容验证;定期 canary 比对用) ──
fp = [round(x, 6) for x in vec[:8]]
import os
fpdir = os.path.expanduser("~/.local/share/embed-canary"); os.makedirs(fpdir, exist_ok=True)
fpp = f"{fpdir}/{name}-fingerprint.json"
open(fpp, "w").write(json.dumps({"probe": "fixed", "fp8": fp}))
print(f"  向量指纹已存 {fpp}(持久位置;canary 守卫:定期同输入比对,漂移=权重被覆盖)")
PY
say "✅ 部署完成: POST 127.0.0.1:11434/api/embed model=$NAME"
say "建议:把指纹比对做成定时任务(canary 守卫,事故 #2 的长效防御)"
