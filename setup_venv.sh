#!/bin/bash
# Setup virtual environment and install dependencies

# Create virtual environment
uv venv venv

# Activate virtual environment
source venv/bin/activate

# Install requirements
uv pip install -r requirements.txt

echo "Virtual environment setup complete. Run 'source venv/bin/activate' to activate it, then use aider."