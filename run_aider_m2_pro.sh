#!/bin/bash

# Define the Ollama API base URL
export OLLAMA_API_BASE=http://localhost:11434

# Ensure Ollama is running and has the models pulled
echo "Checking models..."
ollama pull mistral-small:latest
ollama pull devstral:latest

# Aider works better with a larger context window for local models.
# We set the 'ollama_chat' prefix to tell aider to use the chat API.
# The 'architect' mode uses 14b for planning and 7b for writing.

aider \
  --model ollama_chat/devstral:latest \
  --editor-model ollama_chat/mistral-small:latest \
  --architect \
  --map-tokens 1024 \
  --cache-prompts \
  --no-stream
