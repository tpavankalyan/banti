#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

echo ""
echo "Setup complete."
echo ""
echo "REQUIRED before first run:"
echo "  1. Copy .env.example to .env and fill in API keys"
echo "  2. Accept pyannote/embedding model terms at https://huggingface.co/pyannote/embedding"
echo "     then set HF_TOKEN in .env"
echo "  3. Create a free Neo4j Aura instance at https://console.neo4j.io"
echo "     and add NEO4J_URI / NEO4J_USER / NEO4J_PASSWORD to .env"
