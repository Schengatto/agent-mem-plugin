# MemoryMesh API — multi-stage Dockerfile
#
# Stage 1 (builder):  installa deps Python (--require-hashes deferred to F12)
# Stage 2 (runtime):  COPY da builder, user non-root, minimal footprint
#
# Build:
#   docker build -t memorymesh/api:1.0.0 ./api
# Run:
#   docker run --read-only --cap-drop=ALL --user 1000:1000 memorymesh/api:1.0.0

# ══════════════════════════════════════════════════════════════════════════
# Stage 1: builder
# ══════════════════════════════════════════════════════════════════════════
FROM python:3.14.4-slim AS builder

# Pin del base by digest (da aggiornare periodicamente con `docker pull && docker inspect`)
# Esempio (placeholder — da sostituire con digest reale al primo build):
# FROM python:3.14.4-slim@sha256:0000000000000000000000000000000000000000000000000000000000000000

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_ROOT_USER_ACTION=ignore

# Build dependencies (tolte nel runtime)
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      curl \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Copy solo requirements per maximizzare docker layer cache
COPY requirements.txt ./

# TODO F12: switch to --require-hashes -r requirements-hashes.txt
# To generate: docker run --rm -v $(pwd):/w -w /w python:3.14.4-slim \
#   sh -c "pip install pip-tools && pip-compile --generate-hashes requirements.in"
RUN pip install --user -r requirements.txt

# ══════════════════════════════════════════════════════════════════════════
# Stage 2: runtime (minimal, non-root)
# ══════════════════════════════════════════════════════════════════════════
FROM python:3.14.4-slim AS runtime

# Stesso digest pin del builder
# FROM python:3.14.4-slim@sha256:0000000000000000000000000000000000000000000000000000000000000000

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/home/mm/.local/bin:${PATH}"

# Runtime deps only (libpq per asyncpg, tini per signal handling)
RUN apt-get update && apt-get install -y --no-install-recommends \
      libpq5 \
      tini \
      curl \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# User non-root con UID fisso 1000 (deve matchare docker-compose.yml)
RUN groupadd --system --gid 1000 mm \
    && useradd --system --uid 1000 --gid mm --create-home \
               --home-dir /home/mm --shell /sbin/nologin mm

WORKDIR /app

# Copia le deps installate in builder (solo --user install)
COPY --from=builder --chown=mm:mm /root/.local /home/mm/.local

# Copia applicazione
COPY --chown=mm:mm app/ ./app/
COPY --chown=mm:mm alembic.ini ./
COPY --chown=mm:mm alembic/ ./alembic/

# Static files Nuxt (build prodotto da `make ui-build`)
# La directory potrebbe essere vuota in dev; verrà popolata da CI/CD
COPY --chown=mm:mm static/ ./app/static/

USER mm

# Endpoint default — API. I workers overrideranno con `command:`.
EXPOSE 8000
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "2"]

# Healthcheck di livello container (compose può comunque overridarlo)
HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:8000/health').status==200 else 1)"

# Metadata OCI (SBOM, provenance)
LABEL org.opencontainers.image.source="https://github.com/schengatto/memorymesh" \
      org.opencontainers.image.description="MemoryMesh API + workers" \
      org.opencontainers.image.licenses="MIT"
