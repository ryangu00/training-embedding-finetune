#!/usr/bin/env python3
"""merge-and-verify.py [batch_dir] [out_file] [eval_file]
合并 fanout 产出为训练集:去重 + schema 校验 + 失败统计 + (可选)剔除与评测集重叠的文档。
评测集泄漏是特化训练最常见的自欺:训练集里混入 eval 文档 → 指标虚高。给 eval_file 即自动剔除。"""
import json, os, glob, sys
from collections import Counter

BATCH_DIR = sys.argv[1] if len(sys.argv) > 1 else "./train-batch"
OUT_FILE = sys.argv[2] if len(sys.argv) > 2 else "./trainset.jsonl"
EVAL_FILE = sys.argv[3] if len(sys.argv) > 3 else None

# 1. 评测集文档 id 排除名单(防训练/评测泄漏)
eval_ids = set()
if EVAL_FILE and os.path.exists(EVAL_FILE):
    for line in open(EVAL_FILE):
        line = line.strip()
        if line:
            eval_ids.add(json.loads(line).get("gold_id") or json.loads(line).get("source_id"))
    print(f"评测集排除名单: {len(eval_ids)} 篇")

# 2. 合并+统计
rows, seen, stats = [], set(), Counter()
for fp in sorted(glob.glob(os.path.join(BATCH_DIR, "*.jsonl"))):
    for line in open(fp):
        line = line.strip()
        if not line:
            continue
        d = json.loads(line)
        if "_error" in d:
            stats[d["_error"].split(":")[0]] += 1
            continue
        if d.get("source_id") in eval_ids:
            stats["excluded_eval_overlap"] += 1
            continue
        if not all(isinstance(d.get(k), str) and d[k].strip() for k in ("query", "positive", "negative")):
            stats["schema_fail"] += 1
            continue
        key = (d["query"].strip(), d["positive"][:80])
        if key in seen:
            stats["dup"] += 1
            continue
        seen.add(key)
        rows.append(d)
        stats["ok"] += 1

with open(OUT_FILE, "w") as f:
    for d in rows:
        f.write(json.dumps(d, ensure_ascii=False) + "\n")

print(f"训练集: {len(rows)} 条 → {OUT_FILE}")
print("统计(失败率是训练集质量的第一信号):")
for k, v in stats.most_common():
    print(f"  {k}: {v}")
