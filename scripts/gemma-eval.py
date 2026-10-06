#!/usr/bin/env python3
"""Needle-recall eval for local Gemma (and Apple Intelligence) insights.

Usage: scripts/gemma-eval.py <transcript.txt> [--app dBrief-Beta.app] [--label baseline]
                             [--engine gemma|apple]

Plants 3 unique facts at 10% / 50% / 90% of the transcript's lines, runs the
helper's --eval-insights mode, and reports recall per position, a repetition ratio,
elapsed time and peak MLX memory. Appends one line per run to
docs/diagnostics/gemma-eval.jsonl so phases can be compared.

--engine apple runs the in-process Apple Intelligence analysis through the env-gated
AppleAnalysisEvalTests (`swift test`), from the repository root. A run that fails is
logged as a row with an `error` field and 0/3 recall.
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

def part_hits(dump_path):
    """Per-part needle presence (booleans only) from the dev-only notes dump; the dump
    holds private content, so it is deleted here."""
    try:
        with open(dump_path) as f:
            parts = json.load(f)
    except (OSError, ValueError):
        return None
    finally:
        try: os.unlink(dump_path)
        except OSError: pass
    out = []
    for n in parts:
        text = json.dumps(n).lower()
        out.append({f"{int(frac*100)}%": probe in text for frac, _, probe in NEEDLES})
    return out

def run_gemma(a, transcript_path):
    """Returns (report, diagnostics_text) from the helper's --eval-insights mode."""
    base = os.path.expanduser("~/Library/Application Support/com.dbrief.app.beta/LocalAIPlugin")
    helper = os.path.join(a.app, "Contents/MacOS/dBriefMLHost")
    out = subprocess.run([helper, "--support-base", base, "--eval-insights", transcript_path, "--language", a.language],
                         capture_output=True, text=True)
    if out.returncode != 0 or not out.stdout.strip():
        print(f"helper failed, return code {out.returncode}")
        print("\n".join(l for l in out.stdout.splitlines() if l.startswith('{"error"')))
        print("\n".join(out.stderr.splitlines()[-20:]))
        sys.exit(1)
    # mlx-swift-lm prints warnings to stdout after the report; take the last JSON line
    json_lines = [l for l in out.stdout.strip().splitlines() if l.startswith("{")]
    if not json_lines:
        print("helper produced no JSON report on stdout")
        print("\n".join(out.stderr.splitlines()[-20:]))
        sys.exit(1)
    report = json.loads(json_lines[-1])
    if "error" in report:
        print(report["error"]); sys.exit(1)
    return report, out.stderr

def run_apple(a, transcript_path):
    """Returns (report, diagnostics_text) from AppleAnalysisEvalTests via `swift test`."""
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    env = dict(os.environ, DBRIEF_APPLE_EVAL="1", DBRIEF_EVAL_TRANSCRIPT=transcript_path)
    out = subprocess.run(["swift", "test", "--filter", "AppleAnalysisEvalTests"],
                         cwd=repo, env=env, capture_output=True, text=True)
    combined = out.stdout + "\n" + out.stderr
    lines = [l for l in combined.splitlines() if l.startswith("APPLE_ANALYSIS ")]
    if not lines:
        print(f"swift test produced no APPLE_ANALYSIS report, return code {out.returncode}")
        print("\n".join(combined.splitlines()[-30:]))
        sys.exit(1)
    report = json.loads(lines[-1][len("APPLE_ANALYSIS "):])
    report.setdefault("peak_memory_mb", None)
    return report, combined

def main():
    p = argparse.ArgumentParser()
    p.add_argument("transcript"); p.add_argument("--app", default="dBrief-Beta.app")
    p.add_argument("--label", default="run"); p.add_argument("--language", default="match")
    p.add_argument("--engine", choices=["gemma", "apple"], default="gemma")
    a = p.parse_args()
    with open(a.transcript) as f:
        planted = plant(f.read())
    dump_path = os.path.join(tempfile.gettempdir(), f"dbrief-notes-dump-{os.getpid()}.json")
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as tmp:
        tmp.write(planted)
    hits = None
    try:
        os.environ["DBRIEF_EVAL_NOTES_DUMP"] = dump_path
        report, diagnostics = (run_apple if a.engine == "apple" else run_gemma)(a, tmp.name)
    finally:
        os.unlink(tmp.name)  # planted transcript holds private content
        hits = part_hits(dump_path)  # also deletes the dump, even if the run failed or exited
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    results_dir = os.path.expanduser("~/gemma-eval/results")
    os.makedirs(results_dir, exist_ok=True)
    name = f"{a.label}-{os.path.splitext(os.path.basename(a.transcript))[0]}-{stamp}.json"
    with open(os.path.join(results_dir, name), "w") as f:
        f.write(json.dumps(report) + "\n")
    # Map-reduce path: the eval harness prints each `analyzingPart` state to stderr.
    parts = re.findall(r"analyzingPart\(index: \d+, total: (\d+)\)", diagnostics)
    path = f"map-reduce ({parts[0]} parts)" if parts else "single-pass"
    row = {"label": a.label, "engine": a.engine, "date": datetime.date.today().isoformat(),
           "input_chars": report["input_chars"], "elapsed_s": round(report["elapsed_s"], 1),
           "peak_memory_mb": report.get("peak_memory_mb"), "path": path}
    if "error" in report:  # Apple only: a failed run scores 0/3
        row.update({"recall": {f"{int(frac*100)}%": False for frac, _, _ in NEEDLES}, "error": report["error"],
                    "action_items": 0, "summary_chars": 0, "summary_complete": False})
    else:
        r = report["result"]
        haystack = "\n".join([r.get("title_concept", ""), r["summary"], *r["action_items"], *r.get("tags", [])]).lower()
        row.update({"recall": {f"{int(frac*100)}%": probe in haystack for frac, _, probe in NEEDLES},
                    "repetition": round(repetition_ratio(r["summary"]), 3), "action_items": len(r["action_items"]),
                    "summary_chars": len(r["summary"]), "summary_complete": summary_complete(r["summary"])})
    if hits is not None:
        row["part_hits"] = hits
    print(json.dumps(row, indent=2))
    os.makedirs("docs/diagnostics", exist_ok=True)
    with open("docs/diagnostics/gemma-eval.jsonl", "a") as log:
        log.write(json.dumps(row) + "\n")

if __name__ == "__main__":
    main()
