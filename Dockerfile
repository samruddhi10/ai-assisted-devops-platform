# python:3.12-slim-bookworm: Debian slim is smaller than the full image (fewer
# packages, smaller attack surface) and more reliable than Alpine for CPython
# wheels (avoids musl vs glibc build failures). Pin major.minor; never use :latest.
FROM python:3.12-slim-bookworm AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /build

# Install dependencies as a separate layer so app-code changes do not rebuild wheels.
COPY app/requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt \
    && find /install -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true

FROM python:3.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/usr/local/bin:${PATH}" \
    HOME=/app

# Dedicated UID/GID (>=10000) avoids colliding with common host UIDs and works
# with Kubernetes runAsNonRoot + runAsUser. nologin prevents interactive shells.
RUN groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid app --home /app --shell /usr/sbin/nologin app \
    && mkdir -p /app \
    && chown app:app /app

WORKDIR /app

# Copy only installed packages into the runtime image (no pip cache, no compilers).
COPY --from=builder /install /usr/local

# App code owned by the runtime user. Installs stay root-owned so the process
# cannot rewrite site-packages after start.
COPY --chown=app:app --chmod=0444 app/app.py .

USER app

EXPOSE 5000

# Healthcheck uses the stdlib (no curl/wget in the image; extra packages enlarge
# the attack surface). Runs as USER app, not root.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:5000/health', timeout=3)"

# Flask's built-in server is for development only. Gunicorn is in requirements.txt.
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "--threads", "2", "--timeout", "30", "--access-logfile", "-", "--error-logfile", "-", "app:app"]
