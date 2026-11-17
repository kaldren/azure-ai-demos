"""Query the policy index directly, with no agent and no LLM, to see what retrieval returns.

This isolates diagram hop 4. When the agent gives a wrong answer, check here first: did
search return the right chunk? If not, the problem is retrieval (chunking, query type), not
the model.

  uv run search.py "hotel limit in London"                  # hybrid + semantic (the agent's default)
  uv run search.py "hotel limit in London" --mode keyword   # BM25 only
  uv run search.py "hotel limit in London" --mode vector    # embeddings only
"""

import argparse
import os

from azure.identity import DefaultAzureCredential
from azure.search.documents import SearchClient
from azure.search.documents.models import VectorizableTextQuery
from dotenv import load_dotenv

# Mirrors the AI Search tool's query_type values, so you can compare like for like.
MODES = ["keyword", "vector", "hybrid", "semantic-hybrid"]


def main() -> None:
    load_dotenv()
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("query")
    parser.add_argument("--mode", choices=MODES, default="semantic-hybrid")
    parser.add_argument("--top", type=int, default=3)
    args = parser.parse_args()

    client = SearchClient(os.environ["SEARCH_ENDPOINT"], os.environ["SEARCH_INDEX_NAME"], DefaultAzureCredential())

    kwargs: dict = {"top": args.top, "select": ["id", "title", "content"]}
    if args.mode != "vector":
        kwargs["search_text"] = args.query
    if args.mode != "keyword":
        # Plain text in, and the index's vectorizer embeds it server-side, exactly as for the agent.
        kwargs["vector_queries"] = [
            VectorizableTextQuery(text=args.query, k_nearest_neighbors=50, fields="content_vector")
        ]
    if args.mode == "semantic-hybrid":
        kwargs["query_type"] = "semantic"
        kwargs["semantic_configuration_name"] = "default"

    print(f"[{args.mode}] {args.query}\n")
    for rank, doc in enumerate(client.search(**kwargs), start=1):
        reranker = doc.get("@search.reranker_score")
        score = f"score={doc['@search.score']:.4f}" + (f" reranker={reranker:.2f}" if reranker is not None else "")
        snippet = " ".join(doc["content"].split())[:160]
        print(f"{rank}. {doc['title']}  ({score})\n   {snippet}…\n")


if __name__ == "__main__":
    main()
