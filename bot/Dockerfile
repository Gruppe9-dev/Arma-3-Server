FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy bot source (ssh_key and .env are excluded via .dockerignore and volume-mounted)
COPY . .

CMD ["python", "-u", "main.py"]
