#!/usr/bin/env python3
"""Needle-recall eval for local Gemma insights.

Usage: scripts/gemma-eval.py <transcript.txt> [--app dBrief-Beta.app] [--label baseline]

Plants 3 unique facts at 10% / 50% / 90% of the transcript's lines, runs the
helper's --eval-insights mode, and reports recall per position, a repetition ratio,
elapsed time and peak MLX memory. Appends one line per run to
docs/diagnostics/gemma-eval.jsonl so phases can be compared.
"""
import argparse, json, os, re, subprocess, sys, tempfile, datetime

NEEDLES = [
    (0.10, "Marisol: Action item for me, I will send the Kestrel vendor contract to legal by Thursday.", "kestrel"),
    (0.50, "Dewitt: Okay, decision made, we move the Halcyon launch to March 14th.", "halcyon"),
    (0.90, "Priya: I'll own the Brightwater migration runbook and share it next Monday.", "brightwater"),
]

def plant(text):
    lines = text.split("\n")
    if len(lines) < 10:  # unlabelled transcript (one line): split on sentences instead
        lines = re.split(r"(?<=[.!?])\s+", text)
    for frac, line, _ in sorted(NEEDLES, reverse=True):
        lines.insert(int(len(lines) * frac), line)
    return "\n".join(lines)

def repetition_ratio(text):
    sentences = [s.strip().lower() for s in re.split(r"(?<=[.!?])\s+", text) if len(s.strip()) > 20]
    return 0.0 if not sentences else 1 - len(set(sentences)) / len(sentences)

def summary_complete(summary):
    """Simple truncation check: the stripped summary must end with sentence-final
    punctuation, optionally followed by closing brackets/quotes (so `.)` and `."`
    pass). A mid-sentence cut such as "(e.g.," fails."""
    s = summary.strip()
    return bool(s) and s[-1] in ".!?…)]'’”\""

def main():
    p = argparse.ArgumentParser()
    p.add_argument("transcript"); p.add_argument("--app", default="dBrief-Beta.app")
    p.add_argument("--label", default="run"); p.add_argument("--language", default="match")
    a = p.parse_args()
    base = os.path.expanduser("~/Library/Application Support/com.dbrief.app.beta/LocalAIPlugin")
    with open(a.transcript) as f:
        planted = plant(f.read())
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as tmp:
        tmp.write(planted)
    helper = os.path.join(a.app, "Contents/MacOS/dBriefMLHost")
    try:
        out = subprocess.run([helper, "--support-base", base, "--eval-insights", tmp.name, "--language", a.language],
                             capture_output=True, text=True)
    finally:
        os.unlink(tmp.name)  # planted transcript holds private content
    if out.returncode != 0 or not out.stdout.strip():
        print(f"helper failed, return code {out.returncode}")
        print("\n".join(out.stderr.splitlines()[-20:]))
        sys.exit(1)
    # mlx-swift-lm prints warnings to stdout after the report; take the last JSON line
    json_lines = [l for l in out.stdout.strip().splitlines() if l.startswith("{")]
    if not json_lines:
        print("helper produced no JSON report on stdout")
        print("\n".join(out.stderr.splitlines()[-20:]))
        sys.exit(1)
    last = json_lines[-1]
    report = json.loads(last)
    if "error" in report:
        print(report["error"]); sys.exit(1)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    results_dir = os.path.expanduser("~/gemma-eval/results")
    os.makedirs(results_dir, exist_ok=True)
    name = f"{a.label}-{os.path.splitext(os.path.basename(a.transcript))[0]}-{stamp}.json"
    with open(os.path.join(results_dir, name), "w") as f:
        f.write(last + "\n")
    r = report["result"]
    haystack = "\n".join([r.get("title_concept", ""), r["summary"], *r["action_items"], *r.get("tags", [])]).lower()
    recall = {f"{int(frac*100)}%": probe in haystack for frac, _, probe in NEEDLES}
    # Map-reduce path: the eval harness prints each `analyzingPart` state to stderr.
    parts = re.findall(r"analyzingPart\(index: \d+, total: (\d+)\)", out.stderr)
    path = f"map-reduce ({parts[0]} parts)" if parts else "single-pass"
    row = {"label": a.label, "date": datetime.date.today().isoformat(), "input_chars": report["input_chars"],
           "elapsed_s": round(report["elapsed_s"], 1), "peak_memory_mb": report["peak_memory_mb"],
           "recall": recall, "repetition": round(repetition_ratio(r["summary"]), 3),
           "path": path, "action_items": len(r["action_items"]),
           "summary_chars": len(r["summary"]), "summary_complete": summary_complete(r["summary"])}
    print(json.dumps(row, indent=2))
    os.makedirs("docs/diagnostics", exist_ok=True)
    with open("docs/diagnostics/gemma-eval.jsonl", "a") as log:
        log.write(json.dumps(row) + "\n")

if __name__ == "__main__":
    main()
