#!/usr/bin/env python3
"""Transcript-chat eval for local Gemma (dBriefMLHost --eval-chat).

Usage: scripts/chat-eval.py <transcript.txt> [--app dBrief-Beta.app] --label baseline-per-message [--fresh-session-per-question]

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

def main():
    p = argparse.ArgumentParser()
    p.add_argument("transcript"); p.add_argument("--app", default="dBrief-Beta.app")
    p.add_argument("--label", default="run"); p.add_argument("--mode", default="full")
    p.add_argument("--fresh-session-per-question", action="store_true")
    a = p.parse_args()
    base = os.path.expanduser("~/Library/Application Support/com.dbrief.app.beta/LocalAIPlugin")
    name = os.path.splitext(os.path.basename(a.transcript))[0]
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
        row["questions"] = []
        for (q, probes), ans in zip(QUESTIONS, report["answers"]):
            low = ans["answer"].lower()
            row["questions"].append({"hit": all(x in low for x in probes),
                                     "first_token_s": round(ans["first_token_s"], 2),
                                     "total_s": round(ans["total_s"], 2),
                                     "answer_chars": len(ans["answer"])})
    print(json.dumps(row, indent=2))
    os.makedirs("docs/diagnostics", exist_ok=True)
    with open("docs/diagnostics/chat-eval.jsonl", "a") as log:
        log.write(json.dumps(row) + "\n")

if __name__ == "__main__":
    main()
