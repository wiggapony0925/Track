# Use official lightweight Python image
FROM python:3.11-slim

# Install system dependencies required by LightGBM (OpenMP runtime)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgomp1 \
 && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy requirements and install
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the app code
COPY . .

# Expose the port (FastAPI default is 8000, cloud envs usually set $PORT)
EXPOSE 8000

# Command to run the app — uses $PORT if set by the cloud provider, defaults to 8000
# gunicorn with uvicorn workers gives us:
#   - Worker health monitoring & automatic restarts for stuck workers
#   - Graceful reloads on deploy
#   - Multiple workers (WEB_CONCURRENCY=2 on Standard plan, 2 GB RAM)
# --timeout 120: allow up to 2 min for cold-cache /nearby/grouped (fetches 7+ MTA feeds)
# --graceful-timeout 30: workers get 30s to finish in-flight requests on shutdown
# --no-access-log + --log-level warning: request logging handled by TrackLogger middleware
CMD ["sh", "-c", "gunicorn app.main:app -k uvicorn.workers.UvicornWorker -w ${WEB_CONCURRENCY:-1} --bind 0.0.0.0:${PORT:-8000} --timeout 120 --graceful-timeout 30 --access-logfile /dev/null --log-level warning"]
