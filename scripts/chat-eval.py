#!/usr/bin/env python3
"""Transcript-chat eval for local Gemma (dBriefMLHost --eval-chat).

Usage: scripts/chat-eval.py <transcript.txt> [--app dBrief-Beta.app] --label baseline-per-message [--fresh-session-per-question]
       scripts/chat-eval.py <transcript.txt> --mode long --label gemma-long-v1 [--dump-index ~/gemma-eval/L-index.json]
       scripts/chat-eval.py <transcript.txt> --engine apple --label apple-long-v1 [--reuse-index] [--apple-configs default,p40,baseline]
       scripts/chat-eval.py <transcript.txt> --retrieval [--embed-model <hf-id>]...

--retrieval plants the same 3 facts, runs the helper's --eval-retrieval mode once per
--embed-model (default: every candidate below) and prints the 1-based rank of the
window holding each needle under cosine / BM25 / fused (RRF). Never prints text.

--mode long first runs the map-reduce analysis (for part notes, as processing does),
then asks every question the way Transcript Chat does for a long recording on Gemma:
overview + hybrid (e5 + BM25, RRF) excerpts on one warm session. It also writes the
index dump ({windows, vectors, queries, summary, actionItems, partNotes}) for the
Apple Intelligence eval; that file holds transcript text, so it must stay under
~/gemma-eval/ (default ~/gemma-eval/<transcript>-index.json).

--engine apple runs the helper in long mode (writing the index dump, unless --reuse-index
reuses an existing one), then `swift test --filter AppleChatEvalTests` over that dump with
DBRIEF_APPLE_EVAL=1, and scores the answers with the same probes (one row per config:
default = shipped profile (excerpts 30% / overview 25%), p40 = excerpts 40% / overview 15%, baseline = old head+tail
truncation). Answers go to a results file only, never stdout. The dump is deleted
afterwards (--keep-index to keep it) since it holds private transcript text.

Plants 3 facts (see gemma-eval.py), asks 4 questions, scores each answer by probe
substrings (all must be present, case-insensitive). Raw results go to
~/gemma-eval/results/; one row per run is appended to docs/diagnostics/chat-eval.jsonl
(gitignored). Never prints answer text.
"""
import argparse, importlib.util, json, os, subprocess, sys, tempfile, datetime

_spec = importlib.util.spec_from_file_location("gemma_eval", os.path.join(os.path.dirname(os.path.abspath(__file__)), "gemma-eval.py"))
_ge = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(_ge)
plant = _ge.plant

QUESTIONS = [
    ("Who is sending the Kestrel vendor contract to legal, and by when?", ["marisol", "thursday"]),
    ("What was decided about the Halcyon launch date?", ["march 14"]),
    ("What will Priya share next Monday?", ["brightwater"]),
    ("List every action item and owner mentioned in the meeting.", ["marisol", "priya"]),  # exhaustive
]

# BAAI/bge-m3 omitted: its repo has no root *.safetensors (pytorch_model.bin + onnx/ only), so it can't load.
EMBED_MODELS = ["mlx-community/embeddinggemma-300m-4bit", "intfloat/multilingual-e5-small"]

def run_retrieval(a, base, name):
    with open(a.transcript) as f:
        planted = plant(f.read())
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as tmp:
        tmp.write(planted)
    results_dir = os.path.expanduser("~/gemma-eval/results"); os.makedirs(results_dir, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    rows = []
    try:
        for model in a.embed_model or EMBED_MODELS:
            cmd = [os.path.join(a.app, "Contents/MacOS/dBriefMLHost"), "--support-base", base,
                   "--eval-retrieval", tmp.name, "--embed-model", model]
            out = subprocess.run(cmd, capture_output=True, text=True)
            lines = [l for l in out.stdout.strip().splitlines() if l.startswith("{")]
            report = json.loads(lines[-1]) if lines else {"error": f"no report, rc={out.returncode}"}
            if "error" in report or out.returncode != 0:
                report.setdefault("error", f"rc={out.returncode}")
                report["stderr_tail"] = " | ".join(out.stderr.splitlines()[-3:])[:400]
            report["model"] = model
            rows.append(report)
            with open(os.path.join(results_dir, f"retrieval-{name}-{model.replace('/', '_')}-{stamp}.json"), "w") as f:
                f.write(json.dumps(report) + "\n")
    finally:
        os.unlink(tmp.name)  # planted transcript holds private content
    fmt = lambda r: "-" if r is None else str(r)
    print(f"{'model':40} {'dims':>5} {'win':>4} {'docs_s':>7}  " + "  ".join(f"{p:^17}" for p in ["kestrel", "halcyon", "brightwater"]) + "  fused_total")
    print(f"{'':40} {'':>5} {'':>4} {'':>7}  " + "  ".join(f"{'cos/bm25/fused':^17}" for _ in range(3)))
    for r in rows:
        if "error" in r:
            print(f"{r['model']:40} ERROR {str(r['error'])[:200]} {r.get('stderr_tail', '')}"); continue
        cells = [f"{fmt(n['cosine'])}/{fmt(n['bm25'])}/{fmt(n['fused'])}" for n in r["needles"]]
        fused = [n["fused"] for n in r["needles"]]
        total = sum(fused) if all(x is not None for x in fused) else None
        print(f"{r['model']:40} {r['dims']:>5} {r['windows']:>4} {r['embed_docs_s']:>7.1f}  "
              + "  ".join(f"{c:^17}" for c in cells) + f"  {fmt(total)}")

def run_apple(a, name, dump):
    results_dir = os.path.expanduser("~/gemma-eval/results"); os.makedirs(results_dir, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    out_path = os.path.join(results_dir, f"chat-{a.label}-{name}-{stamp}.json")
    env = dict(os.environ, DBRIEF_APPLE_EVAL="1", DBRIEF_EVAL_INDEX=dump, DBRIEF_APPLE_EVAL_OUT=out_path,
               DBRIEF_APPLE_EVAL_CONFIGS=a.apple_configs)
    try:
        proc = subprocess.run(["swift", "test", "--filter", "AppleChatEvalTests"], env=env, capture_output=True, text=True)
    finally:
        if not a.keep_index and os.path.exists(dump):
            os.unlink(dump)  # holds private transcript text
    if not os.path.exists(out_path):
        print(json.dumps({"label": a.label, "error": f"no apple report, rc={proc.returncode}",
                          "stderr_tail": " | ".join((proc.stdout + proc.stderr).splitlines()[-4:])[:400]}))
        return 1
    with open(out_path) as f:
        report = json.load(f)
    os.makedirs("docs/diagnostics", exist_ok=True)
    for cfg in report["configs"]:
        row = {"label": f"{a.label}-{cfg['config']}", "transcript": name, "date": datetime.date.today().isoformat(),
               "mode": "apple-long", "excerpt_budget": cfg["excerpt_budget"], "overview_budget": cfg["overview_budget"],
               "questions": []}
        for (q, probes), ans in zip(QUESTIONS, cfg["answers"]):
            low = ans.get("answer", "").lower()
            row["questions"].append({"hit": all(x in low for x in probes), "total_s": round(ans["total_s"], 2),
                                     **({"overflow_retry": True} if ans.get("overflow_retry") else {}),
                                     **({"error": ans["error"]} if "error" in ans else {}),
                                     "excerpt_tokens": ans.get("excerpt_tokens", 0), "answer_chars": len(low)})
        print(json.dumps(row, indent=2))
        with open("docs/diagnostics/chat-eval.jsonl", "a") as log:
            log.write(json.dumps(row) + "\n")
    return 0

def main():
    p = argparse.ArgumentParser()
    p.add_argument("transcript"); p.add_argument("--app", default="dBrief-Beta.app")
    p.add_argument("--label", default="run"); p.add_argument("--mode", default="full")
    p.add_argument("--fresh-session-per-question", action="store_true")
    p.add_argument("--retrieval", action="store_true")
    p.add_argument("--embed-model", action="append")
    p.add_argument("--dump-index")
    p.add_argument("--engine", default="gemma", choices=["gemma", "apple"])
    p.add_argument("--reuse-index", action="store_true"); p.add_argument("--keep-index", action="store_true")
    p.add_argument("--apple-configs", default="default")
    a = p.parse_args()
    base = os.path.expanduser("~/Library/Application Support/com.dbrief.app.beta/LocalAIPlugin")
    name = os.path.splitext(os.path.basename(a.transcript))[0]
    if a.retrieval:
        return run_retrieval(a, base, name)
    if a.engine == "apple":
        a.mode = "long"
        a.dump_index = a.dump_index or f"~/gemma-eval/{name}-index.json"
        dump = os.path.realpath(os.path.expanduser(a.dump_index))
        if a.reuse_index:
            if not dump.startswith(os.path.realpath(os.path.expanduser("~/gemma-eval")) + os.sep):
                sys.exit("--dump-index must be under ~/gemma-eval/")
            return run_apple(a, name, dump)
        a.label = "gemma-" + a.label
    with open(a.transcript) as f:
        planted = plant(f.read())
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as tmp:
        tmp.write(planted)
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as qf:
        json.dump([q for q, _ in QUESTIONS], qf)
    cmd = [os.path.join(a.app, "Contents/MacOS/dBriefMLHost"), "--support-base", base,
           "--eval-chat", tmp.name, "--questions", qf.name, "--mode", a.mode]
    if a.fresh_session_per_question:
        cmd.append("--fresh-session-per-question")
    if a.mode == "long":
        eval_dir = os.path.realpath(os.path.expanduser("~/gemma-eval"))
        dump = os.path.realpath(os.path.expanduser(a.dump_index or f"~/gemma-eval/{name}-index.json"))
        if not dump.startswith(eval_dir + os.sep):
            os.unlink(tmp.name); os.unlink(qf.name)
            sys.exit("--dump-index must be under ~/gemma-eval/ (it holds transcript text)")
        cmd += ["--dump-index", dump]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True)
    finally:
        os.unlink(tmp.name); os.unlink(qf.name)  # planted transcript holds private content
    json_lines = [l for l in out.stdout.strip().splitlines() if l.startswith("{")]
    row = {"label": a.label, "transcript": name, "date": datetime.date.today().isoformat(),
           "fresh_session": a.fresh_session_per_question}
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    results_dir = os.path.expanduser("~/gemma-eval/results"); os.makedirs(results_dir, exist_ok=True)
    report = json.loads(json_lines[-1]) if json_lines else {"error": f"no report, rc={out.returncode}"}
    with open(os.path.join(results_dir, f"chat-{a.label}-{name}-{stamp}.json"), "w") as f:
        f.write((json_lines[-1] if json_lines else json.dumps(report)) + "\n")
    if "error" in report or out.returncode != 0:
        row["error"] = str(report.get("error", f"rc={out.returncode}"))[:300]
        row["stderr_tail"] = " | ".join(out.stderr.splitlines()[-3:])[:300]
    else:
        row.update(mode=report["mode"], input_chars=report["input_chars"], peak_memory_mb=report["peak_memory_mb"])
        for k in ("planned_mode", "transcript_tokens", "windows", "part_notes", "overview_source",
                  "overview_tokens", "analysis_s", "index_s"):
            if k in report:
                row[k] = round(report[k], 2) if isinstance(report[k], float) else report[k]
        row["questions"] = []
        for (q, probes), ans in zip(QUESTIONS, report["answers"]):
            low = ans["answer"].lower()
            row["questions"].append({"hit": all(x in low for x in probes),
                                     "first_token_s": round(ans["first_token_s"], 2),
                                     "total_s": round(ans["total_s"], 2),
                                     **({"excerpt_tokens": ans["excerpt_tokens"]} if "excerpt_tokens" in ans else {}),
                                     "answer_chars": len(ans["answer"])})
    print(json.dumps(row, indent=2))
    os.makedirs("docs/diagnostics", exist_ok=True)
    with open("docs/diagnostics/chat-eval.jsonl", "a") as log:
        log.write(json.dumps(row) + "\n")
    if a.engine == "apple" and "error" not in row:
        a.label = a.label[len("gemma-"):]
        return run_apple(a, name, dump)

if __name__ == "__main__":
    main()
