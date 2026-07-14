# ---------------------------------------------------------------
# Stage 1: builder
# Compiles wheels and builds a virtualenv. Build tooling (pip cache,
# compilers if needed) never reaches the final image.
# ---------------------------------------------------------------
FROM python:3.12-slim AS builder

WORKDIR /build

COPY requirements.txt .

RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir --upgrade pip \
    && /opt/venv/bin/pip install --no-cache-dir -r requirements.txt

# ---------------------------------------------------------------
# Stage 2: runtime
# Slim base, only the venv and app code, running as a non-root user
# with a read-only-friendly layout (Principle of Least Privilege).
# ---------------------------------------------------------------
FROM python:3.12-slim AS runtime

# libpq5 is the only OS package psycopg2-binary needs at runtime on slim.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libpq5=17.10-0+deb13u1 \
    && rm -rf /var/lib/apt/lists/*

# Dedicated non-root user with no shell and no home-directory clutter.
RUN groupadd --gid 10001 app \
    && useradd --uid 10001 --gid app --shell /usr/sbin/nologin --create-home app

COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY --chown=app:app app.py .

USER 10001:10001

# Non-privileged port (>1024) so the container never needs CAP_NET_BIND_SERVICE.
EXPOSE 8000

# Uses the interpreter already in the image rather than installing curl, whose
# exact apt pin breaks whenever Debian supersedes it in the archive.
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/healthz')" || exit 1

CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "2", "app:app"]
