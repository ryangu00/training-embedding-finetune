#!/usr/bin/env python3
"""merge-and-verify.py [batch_dir] [out_file] [eval_file]
Merge fan-out output into a training set: dedupe + schema validation + failure stats + (optionally) drop documents overlapping the eval set.
Eval-set leakage is the most common way specialization training fools itself: eval documents mixed into the training set inflate the metrics. Pass eval_file and they are dropped automatically."""
import json, os, glob, sys
from collections import Counter

BATCH_DIR = sys.argv[1] if len(sys.argv) > 1 else "./train-batch"
OUT_FILE = sys.argv[2] if len(sys.argv) > 2 else "./trainset.jsonl"
EVAL_FILE = sys.argv[3] if len(sys.argv) > 3 else None

# 1. Eval-set document-id exclusion list (prevents train/eval leakage)
eval_ids = set()
if EVAL_FILE and os.path.exists(EVAL_FILE):
    for line in open(EVAL_FILE):
        line = line.strip()
        if line:
            eval_ids.add(json.loads(line).get("gold_id") or json.loads(line).get("source_id"))
    print(f"Eval-set exclusion list: {len(eval_ids)} documents")

# 2. Merge + stats
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

print(f"Training set: {len(rows)} samples -> {OUT_FILE}")
print("Stats (the failure rate is the first signal of training-set quality):")
for k, v in stats.most_common():
    print(f"  {k}: {v}")
