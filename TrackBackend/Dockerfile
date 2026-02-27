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
CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8000}"]
