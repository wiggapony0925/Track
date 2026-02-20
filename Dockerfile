# ============================================================
# Root Dockerfile for Render deployment
# ============================================================
# Render clones the full repo and looks for Dockerfile at the
# repository root. This file builds the TrackBackend FastAPI
# application from the TrackBackend/ subdirectory.
# ============================================================

FROM python:3.11-slim

# Set working directory to the backend folder
WORKDIR /app

# Copy requirements first for Docker layer caching
COPY TrackBackend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the backend application code
COPY TrackBackend/app ./app
COPY TrackBackend/settings.json .
COPY TrackBackend/run.py .

# Expose the port (Render sets $PORT automatically)
EXPOSE 8000

# Start the FastAPI server — uses $PORT if set by cloud provider, defaults to 8000
CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8000}"]
