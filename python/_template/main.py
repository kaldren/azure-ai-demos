import os

from azure.identity import DefaultAzureCredential
from dotenv import load_dotenv

load_dotenv()

endpoint = os.environ["AZURE_ENDPOINT"]
credential = DefaultAzureCredential()

print(f"Endpoint: {endpoint}")
# TODO: create your Azure client here using `endpoint` and `credential`.
