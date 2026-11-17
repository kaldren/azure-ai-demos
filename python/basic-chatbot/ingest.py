"""Load the policy documents in data/ into an Azure AI Search index (step 2, offline path).

What happens, in order:
  1. Chunk each Markdown file by its "## " sections. One section = one search document.
  2. Embed every chunk with the text-embedding-3-small deployment on Foundry (your identity).
  3. Create (or update) the index: text fields, a vector field, a *vectorizer*, and a semantic config.
  4. Upload the chunks.

The vectorizer in step 3 matters at query time. The agent's AI Search tool sends plain text,
and the search service embeds it by calling the same deployment with its own managed identity.
Chunks and questions must be embedded by the same model, or the vectors aren't comparable.
"""

import argparse
import os
import re
from pathlib import Path
from urllib.parse import urlparse

from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from azure.search.documents import SearchClient
from azure.search.documents.indexes import SearchIndexClient
from azure.search.documents.indexes.models import (
    AzureOpenAIVectorizer,
    AzureOpenAIVectorizerParameters,
    HnswAlgorithmConfiguration,
    SearchableField,
    SearchField,
    SearchFieldDataType,
    SearchIndex,
    SemanticConfiguration,
    SemanticField,
    SemanticPrioritizedFields,
    SemanticSearch,
    SimpleField,
    VectorSearch,
    VectorSearchProfile,
)
from dotenv import load_dotenv
from openai import OpenAI

DATA_DIR = Path(__file__).parent / "data"
EMBEDDING_DIMENSIONS = 1536  # text-embedding-3-small
# Fictional intranet base URL. The AI Search tool needs a URL field to produce citations.
URL_BASE = "https://intranet.contoso.example/policies"


def slugify(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def chunk_markdown(path: Path) -> list[dict]:
    """Split one Markdown file into one chunk per '## ' section, keeping the document title."""
    text = re.sub(r"<!--.*?-->", "", path.read_text(), flags=re.DOTALL)  # drop HTML comments
    doc_title = re.search(r"^# (.+)$", text, flags=re.MULTILINE).group(1).strip()
    doc_slug = path.stem
    chunks = []
    for section in re.split(r"^## ", text, flags=re.MULTILINE)[1:]:
        heading, _, body = section.partition("\n")
        heading = heading.strip()
        chunks.append(
            {
                "id": f"{doc_slug}-{slugify(heading)}",
                "title": f"{doc_title}: {heading}",
                # Prefixing the title helps both keyword and vector search: a section called
                # "Hotels" is about *travel* hotels, and the body alone doesn't always say so.
                "content": f"{doc_title}: {heading}\n{body.strip()}",
                "url": f"{URL_BASE}/{doc_slug}#{slugify(heading)}",
                "source": path.name,
            }
        )
    return chunks


def build_index(name: str, openai_resource_url: str, embedding_deployment: str) -> SearchIndex:
    return SearchIndex(
        name=name,
        fields=[
            SimpleField(name="id", type=SearchFieldDataType.String, key=True),
            SearchableField(name="title", type=SearchFieldDataType.String),
            SearchableField(name="content", type=SearchFieldDataType.String),
            SimpleField(name="url", type=SearchFieldDataType.String),
            SimpleField(name="source", type=SearchFieldDataType.String, filterable=True),
            SearchField(
                name="content_vector",
                type=SearchFieldDataType.Collection(SearchFieldDataType.Single),
                searchable=True,
                vector_search_dimensions=EMBEDDING_DIMENSIONS,
                vector_search_profile_name="default",
            ),
        ],
        vector_search=VectorSearch(
            algorithms=[HnswAlgorithmConfiguration(name="hnsw")],
            profiles=[
                VectorSearchProfile(
                    name="default", algorithm_configuration_name="hnsw", vectorizer_name="foundry-embeddings"
                )
            ],
            vectorizers=[
                AzureOpenAIVectorizer(
                    vectorizer_name="foundry-embeddings",
                    # No api_key / auth_identity: the search service's system managed identity is used.
                    parameters=AzureOpenAIVectorizerParameters(
                        resource_url=openai_resource_url,
                        deployment_name=embedding_deployment,
                        model_name=embedding_deployment,
                    ),
                )
            ],
        ),
        # Semantic ranker reranks the top keyword/vector hits with a cross-encoder model.
        semantic_search=SemanticSearch(
            default_configuration_name="default",
            configurations=[
                SemanticConfiguration(
                    name="default",
                    prioritized_fields=SemanticPrioritizedFields(
                        title_field=SemanticField(field_name="title"),
                        content_fields=[SemanticField(field_name="content")],
                    ),
                )
            ],
        ),
    )


def main() -> None:
    load_dotenv()
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--recreate", action="store_true", help="Delete and recreate the index first.")
    args = parser.parse_args()

    search_endpoint = os.environ["SEARCH_ENDPOINT"]
    index_name = os.environ["SEARCH_INDEX_NAME"]
    embedding_deployment = os.environ["FOUNDRY_EMBEDDING_DEPLOYMENT"]
    # Same Foundry resource as the project, reached on its Azure OpenAI hostname.
    account = urlparse(os.environ["FOUNDRY_PROJECT_ENDPOINT"]).hostname.split(".")[0]
    openai_resource_url = f"https://{account}.openai.azure.com"

    credential = DefaultAzureCredential()

    chunks = [c for path in sorted(DATA_DIR.glob("*.md")) for c in chunk_markdown(path)]
    print(f"Chunked {len(chunks)} sections from {DATA_DIR.name}/")

    embedder = OpenAI(
        base_url=f"{openai_resource_url}/openai/v1/",
        api_key=get_bearer_token_provider(credential, "https://cognitiveservices.azure.com/.default"),
    )
    response = embedder.embeddings.create(model=embedding_deployment, input=[c["content"] for c in chunks])
    for chunk, item in zip(chunks, response.data):
        chunk["content_vector"] = item.embedding
    print(f"Embedded {len(chunks)} chunks ({response.usage.total_tokens} tokens, {EMBEDDING_DIMENSIONS} dims)")

    index_client = SearchIndexClient(search_endpoint, credential)
    if args.recreate:
        index_client.delete_index(index_name)
        print(f"Deleted index '{index_name}'")
    index_client.create_or_update_index(build_index(index_name, openai_resource_url, embedding_deployment))
    print(f"Index '{index_name}' ready (hybrid vector + semantic)")

    results = SearchClient(search_endpoint, index_name, credential).upload_documents(chunks)
    failed = [r.key for r in results if not r.succeeded]
    print(f"Uploaded {len(results) - len(failed)}/{len(results)} documents" + (f", failed: {failed}" if failed else ""))
    for c in chunks:
        print(f"  {c['id']:<45} {c['title']}")


if __name__ == "__main__":
    main()
