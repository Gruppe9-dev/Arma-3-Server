FROM python:3.12-slim@sha256:f77ac9e44ae96ef2c90b8053ea08c31f8be030f824196b0ae4db6d462c84e51f

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy bot source (ssh_key and .env are excluded via .dockerignore and volume-mounted)
COPY --chown=10001:10001 . .

RUN groupadd --gid 10001 arma-bot \
    && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin arma-bot \
    && mkdir -p /app/data /app/logs \
    && chown -R 10001:10001 /app

ENV HOME=/tmp \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

USER 10001:10001

CMD ["python", "-u", "main.py"]
