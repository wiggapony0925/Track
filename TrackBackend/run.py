import os
import sys
import subprocess

def main():
    """
    Main entry point for the Track Backend.
    Handles virtual environment detection and uvicorn startup.
    """
    # Navigate to the backend directory if needed
    backend_dir = os.path.dirname(os.path.abspath(__file__))
    os.chdir(backend_dir)

    print("🚀 Starting Track Backend...")

    # Define the command to run uvicorn
    # Using 'python -m uvicorn' is more reliable than 'uvicorn' as it handles PATH issues better
    uvicorn_cmd = ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--reload", "--no-access-log"]

    # Check for virtual environment
    venv_python = None
    if os.path.exists(".venv"):
        if os.name == "nt":  # Windows
            venv_python = os.path.join(".venv", "Scripts", "python.exe")
        else:  # macOS/Linux
            venv_python = os.path.join(".venv", "bin", "python")
        
        if os.path.exists(venv_python):
            print(f"📦 Using virtual environment: {venv_python}")
            cmd = [venv_python, "-m"] + uvicorn_cmd
        else:
            venv_python = None

    if not venv_python:
        print("⚠️  Virtual environment not found or invalid. Using system python.")
        cmd = [sys.executable, "-m"] + uvicorn_cmd

    try:
        # Run the server
        subprocess.run(cmd)
    except KeyboardInterrupt:
        print("\n👋 Stopping Track Backend...")
    except Exception as e:
        print(f"❌ Error starting backend: {e}")
        print("\n💡 Tip: Make sure dependencies are installed with: pip install -r requirements.txt")

if __name__ == "__main__":
    main()
