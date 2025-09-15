#!/bin/bash

set -e

echo "🚀 Starting OpenMemory installation..."

# Set environment variables
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
USER="${USER:-$(whoami)}"
NEXT_PUBLIC_API_URL="${NEXT_PUBLIC_API_URL:-http://localhost:8765}"

if [ -z "$OPENAI_API_KEY" ]; then
  echo "❌ OPENAI_API_KEY not set. Please run with: curl -sL https://raw.githubusercontent.com/mem0ai/mem0/main/openmemory/run.sh | OPENAI_API_KEY=your_api_key bash"
  echo "❌ OPENAI_API_KEY not set. You can also set it as global environment variable: export OPENAI_API_KEY=your_api_key"
  exit 1
fi

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
  echo "❌ Docker not found. Please install Docker first."
  exit 1
fi

# Check if docker compose is available
if ! docker compose version &> /dev/null; then
  echo "❌ Docker Compose not found. Please install Docker Compose V2."
  exit 1
fi

# Check if the container "mem0_ui" already exists and remove it if necessary
if [ $(docker ps -aq -f name=mem0_ui) ]; then
  echo "⚠️ Found existing container 'mem0_ui'. Removing it..."
  docker rm -f mem0_ui
fi

# Find an available port starting from 3000
echo "🔍 Looking for available port for frontend..."
for port in {3000..3010}; do
  if ! lsof -i:$port >/dev/null 2>&1; then
    FRONTEND_PORT=$port
    break
  fi
done

if [ -z "$FRONTEND_PORT" ]; then
  echo "❌ Could not find an available port between 3000 and 3010"
  exit 1
fi

# Export required variables for Compose and frontend
export OPENAI_API_KEY
export USER
export NEXT_PUBLIC_API_URL
export NEXT_PUBLIC_USER_ID="$USER"
export FRONTEND_PORT

# Parse vector store selection (env var or flag). Default: qdrant
VECTOR_STORE="${VECTOR_STORE:-milvus}"
EMBEDDING_DIMS="${EMBEDDING_DIMS:-19530}"

for arg in "$@"; do
  case $arg in
    --vector-store=*)
      VECTOR_STORE="${arg#*=}"
      shift
      ;;
    --vector-store)
      VECTOR_STORE="$2"
      shift 2
      ;;
    *)
      ;;
  esac
done

export VECTOR_STORE
echo "🧰 Using vector store: $VECTOR_STORE"


# Function to install vector store specific packages
install_vector_store_packages() {
  local vector_store=$1
  echo "📦 Installing packages for vector store: $vector_store..."
  
  case "$vector_store" in
    qdrant)
      docker exec openmemory-openmemory-mcp-1 pip install "qdrant-client>=1.9.1" || echo "⚠️ Failed to install qdrant packages"
      ;;
    chroma)
      docker exec openmemory-openmemory-mcp-1 pip install "chromadb>=0.4.24" || echo "⚠️ Failed to install chroma packages"
      ;;
    weaviate)
      docker exec openmemory-openmemory-mcp-1 pip install "weaviate-client>=4.4.0,<4.15.0" || echo "⚠️ Failed to install weaviate packages"
      ;;
    faiss)
      docker exec openmemory-openmemory-mcp-1 pip install "faiss-cpu>=1.7.4" || echo "⚠️ Failed to install faiss packages"
      ;;
    pgvector)
      docker exec openmemory-openmemory-mcp-1 pip install "vecs>=0.4.0" "psycopg>=3.2.8" || echo "⚠️ Failed to install pgvector packages"
      ;;
    redis)
      docker exec openmemory-openmemory-mcp-1 pip install "redis>=5.0.0,<6.0.0" "redisvl>=0.1.0,<1.0.0" || echo "⚠️ Failed to install redis packages"
      ;;
    elasticsearch)
      docker exec openmemory-openmemory-mcp-1 pip install "elasticsearch>=8.0.0,<9.0.0" || echo "⚠️ Failed to install elasticsearch packages"
      ;;
    milvus)
      docker exec openmemory-openmemory-mcp-1 pip install "pymilvus>=2.4.0,<2.6.0" || echo "⚠️ Failed to install milvus packages"
      ;;
    *)
      echo "⚠️ Unknown vector store: $vector_store. Installing default qdrant packages."
      docker exec openmemory-openmemory-mcp-1 pip install "qdrant-client>=1.9.1" || echo "⚠️ Failed to install qdrant packages"
      ;;
  esac
}

# Start services
echo "🚀 Starting backend services..."
docker compose up -d

# Wait for container to be ready before installing packages
echo "⏳ Waiting for container to be ready..."
for i in {1..30}; do
  if docker exec openmemory-openmemory-mcp-1 python -c "import sys; print('ready')" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# Install vector store specific packages
install_vector_store_packages "$VECTOR_STORE"

# If a specific vector store is selected, seed the backend config accordingly
if [ "$VECTOR_STORE" = "milvus" ]; then
  echo "⏳ Waiting for API to be ready at ${NEXT_PUBLIC_API_URL}..."
  for i in {1..60}; do
    if curl -fsS "${NEXT_PUBLIC_API_URL}/api/v1/config" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  echo "🧩 Configuring vector store (milvus) in backend..."
  curl -fsS -X PUT "${NEXT_PUBLIC_API_URL}/api/v1/config/mem0/vector_store" \
    -H 'Content-Type: application/json' \
    -d "{\"provider\":\"milvus\",\"config\":{\"collection_name\":\"openmemory\",\"embedding_model_dims\":${EMBEDDING_DIMS},\"url\":\"http://mem0_store:19530\",\"token\":\"\",\"db_name\":\"\",\"metric_type\":\"COSINE\"}}" >/dev/null || true
elif [ "$VECTOR_STORE" = "weaviate" ]; then
  echo "⏳ Waiting for API to be ready at ${NEXT_PUBLIC_API_URL}..."
  for i in {1..60}; do
    if curl -fsS "${NEXT_PUBLIC_API_URL}/api/v1/config" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  echo "🧩 Configuring vector store (weaviate) in backend..."
  curl -fsS -X PUT "${NEXT_PUBLIC_API_URL}/api/v1/config/mem0/vector_store" \
    -H 'Content-Type: application/json' \
    -d "{\"provider\":\"weaviate\",\"config\":{\"collection_name\":\"openmemory\",\"embedding_model_dims\":${EMBEDDING_DIMS},\"cluster_url\":\"http://mem0_store:8080\"}}" >/dev/null || true
elif [ "$VECTOR_STORE" = "redis" ]; then
  echo "⏳ Waiting for API to be ready at ${NEXT_PUBLIC_API_URL}..."
  for i in {1..60}; do
    if curl -fsS "${NEXT_PUBLIC_API_URL}/api/v1/config" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  echo "🧩 Configuring vector store (redis) in backend..."
  curl -fsS -X PUT "${NEXT_PUBLIC_API_URL}/api/v1/config/mem0/vector_store" \
    -H 'Content-Type: application/json' \
    -d "{\"provider\":\"redis\",\"config\":{\"collection_name\":\"openmemory\",\"embedding_model_dims\":${EMBEDDING_DIMS},\"redis_url\":\"redis://mem0_store:6379\"}}" >/dev/null || true
elif [ "$VECTOR_STORE" = "pgvector" ]; then
  echo "⏳ Waiting for API to be ready at ${NEXT_PUBLIC_API_URL}..."
  for i in {1..60}; do
    if curl -fsS "${NEXT_PUBLIC_API_URL}/api/v1/config" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  echo "🧩 Configuring vector store (pgvector) in backend..."
  curl -fsS -X PUT "${NEXT_PUBLIC_API_URL}/api/v1/config/mem0/vector_store" \
    -H 'Content-Type: application/json' \
    -d "{\"provider\":\"pgvector\",\"config\":{\"collection_name\":\"openmemory\",\"embedding_model_dims\":${EMBEDDING_DIMS},\"dbname\":\"mem0\",\"user\":\"mem0\",\"password\":\"mem0\",\"host\":\"mem0_store\",\"port\":5432,\"diskann\":false,\"hnsw\":true}}" >/dev/null || true
elif [ "$VECTOR_STORE" = "qdrant" ]; then
  echo "⏳ Waiting for API to be ready at ${NEXT_PUBLIC_API_URL}..."
  for i in {1..60}; do
    if curl -fsS "${NEXT_PUBLIC_API_URL}/api/v1/config" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  echo "🧩 Configuring vector store (qdrant) in backend..."
  curl -fsS -X PUT "${NEXT_PUBLIC_API_URL}/api/v1/config/mem0/vector_store" \
    -H 'Content-Type: application/json' \
    -d "{\"provider\":\"qdrant\",\"config\":{\"collection_name\":\"openmemory\",\"embedding_model_dims\":${EMBEDDING_DIMS},\"host\":\"mem0_store\",\"port\":6333}}" >/dev/null || true
elif [ "$VECTOR_STORE" = "chroma" ]; then
  echo "⏳ Waiting for API to be ready at ${NEXT_PUBLIC_API_URL}..."
  for i in {1..60}; do
    if curl -fsS "${NEXT_PUBLIC_API_URL}/api/v1/config" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  echo "🧩 Configuring vector store (chroma) in backend..."
  curl -fsS -X PUT "${NEXT_PUBLIC_API_URL}/api/v1/config/mem0/vector_store" \
    -H 'Content-Type: application/json' \
    -d "{\"provider\":\"chroma\",\"config\":{\"collection_name\":\"openmemory\",\"host\":\"mem0_store\",\"port\":8000}}" >/dev/null || true
elif [ "$VECTOR_STORE" = "elasticsearch" ]; then
  echo "⏳ Waiting for API to be ready at ${NEXT_PUBLIC_API_URL}..."
  for i in {1..60}; do
    if curl -fsS "${NEXT_PUBLIC_API_URL}/api/v1/config" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  echo "🧩 Configuring vector store (elasticsearch) in backend..."
  curl -fsS -X PUT "${NEXT_PUBLIC_API_URL}/api/v1/config/mem0/vector_store" \
    -H 'Content-Type: application/json' \
    -d "{\"provider\":\"elasticsearch\",\"config\":{\"collection_name\":\"openmemory\",\"embedding_model_dims\":${EMBEDDING_DIMS},\"host\":\"http://mem0_store\",\"port\":9200,\"user\":\"elastic\",\"password\":\"changeme\",\"verify_certs\":false,\"use_ssl\":false}}" >/dev/null || true
elif [ "$VECTOR_STORE" = "faiss" ]; then
  echo "⏳ Waiting for API to be ready at ${NEXT_PUBLIC_API_URL}..."
  for i in {1..60}; do
    if curl -fsS "${NEXT_PUBLIC_API_URL}/api/v1/config" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  echo "🧩 Configuring vector store (faiss) in backend..."
  curl -fsS -X PUT "${NEXT_PUBLIC_API_URL}/api/v1/config/mem0/vector_store" \
    -H 'Content-Type: application/json' \
    -d "{\"provider\":\"faiss\",\"config\":{\"collection_name\":\"openmemory\",\"embedding_model_dims\":${EMBEDDING_DIMS},\"path\":\"/tmp/faiss\",\"distance_strategy\":\"cosine\"}}" >/dev/null || true
fi