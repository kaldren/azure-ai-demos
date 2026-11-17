"""Measure how agent versions behave on a fixed question set: did they search, were they right?

Each question runs N times, each run in a fresh conversation, so earlier search results can't
leak in (README experiment 7). "Correct" is a keyword check against the policy text. It's
crude, but it's deterministic and good enough to compare versions.

  uv run evaluate.py 2 4              # versions 2 and 4
  uv run evaluate.py 2 4 --runs 2     # fewer runs = fewer tokens
"""

import argparse
import os
import time
from dataclasses import dataclass

from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential
from dotenv import load_dotenv
from openai import RateLimitError


@dataclass
class Case:
    question: str
    expect_any: list[str]  # a correct answer contains at least one of these (case-insensitive)
    kind: str  # policy | missing | general


CASES = [
    Case("What's the hotel limit in Stockholm?", ["220"], "policy"),
    Case("Do I need a receipt for a 20 euro taxi?", ["optional", "not required", "don't need", "do not need", "no receipt", "not need", "under eur 25", "over eur 25"], "policy"),
    Case("Can I work from Spain for a month?", ["20 working days"], "policy"),
    Case("How many vacation days do I get?", ["couldn't find", "could not find", "not find", "don't have", "no information", "not in"], "missing"),
    Case("What's the capital of Sweden?", ["stockholm"], "general"),
]


def run_once(openai, agent: str, version: str, question: str):
    for attempt in range(4):
        try:
            started = time.perf_counter()
            # No conversation ID: each call is independent, so runs can't influence each other.
            response = openai.responses.create(
                input=question,
                extra_body={"agent_reference": {"name": agent, "version": version, "type": "agent_reference"}},
            )
            return response, time.perf_counter() - started
        except RateLimitError:
            time.sleep(30 * (attempt + 1))  # per-minute quota window
    raise RuntimeError("rate limited 4 times in a row")


def main() -> None:
    load_dotenv()
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("versions", nargs="+")
    parser.add_argument("--runs", type=int, default=4)
    parser.add_argument("--pause", type=float, default=3.0, help="Seconds between calls (rate limits).")
    parser.add_argument("--kind", choices=["policy", "missing", "general"], help="Only run cases of this kind.")
    args = parser.parse_args()
    agent = os.environ["FOUNDRY_AGENT_NAME"]

    with AIProjectClient(endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"], credential=DefaultAzureCredential()) as project:
        openai = project.get_openai_client()
        header = f"{'ver':<4}{'kind':<9}{'searched':>9}{'correct':>9}{'avg in-tok':>11}{'avg sec':>9}  question"
        print(header + "\n" + "-" * len(header))
        for version in args.versions:
            totals = {"searched": 0, "correct": 0, "n": 0}
            for case in [c for c in CASES if not args.kind or c.kind == args.kind]:
                searched = correct = tokens = seconds = 0
                for _ in range(args.runs):
                    response, elapsed = run_once(openai, agent, version, case.question)
                    searched += any(item.type == "azure_ai_search_call" for item in response.output)
                    # Models often write typographic apostrophes (couldn’t), so normalize before matching.
                    answer = response.output_text.lower().replace("\u2019", "'")
                    correct += any(e in answer for e in case.expect_any)
                    tokens += response.usage.input_tokens
                    seconds += elapsed
                    time.sleep(args.pause)
                n = args.runs
                totals["searched"] += searched if case.kind != "general" else 0
                totals["correct"] += correct
                totals["n"] += n
                print(
                    f"v{version:<3}{case.kind:<9}{searched:>6}/{n}{correct:>7}/{n}"
                    f"{tokens // n:>11}{seconds / n:>9.1f}  {case.question}",
                    flush=True,
                )
            print(f"v{version} total correct: {totals['correct']}/{totals['n']}\n", flush=True)


if __name__ == "__main__":
    main()
