#!/bin/bash

# start.sh - Clean startup script for TrackBackend
# Terminates any existing process on port 8000 and starts the FastAPI server.

PORT=8000

echo "🚀 Starting Track Backend..."

# Find and kill any process running on the port
PID=$(lsof -t -i:$PORT)
if [ -n "$PID" ]; then
    echo "⚠️  Port $PORT is already in use by PID $PID. Terminating..."
    kill -9 $PID
    sleep 1
fi

echo "✅ Port $PORT is clear."

# Start the uvicorn server
# Using the .venv python if available
if [ -f ".venv/bin/python" ]; then
    echo "📦 Using virtual environment..."
    .venv/bin/python run.py
else
    echo "🐍 Using system python..."
    python3 run.py
fi
