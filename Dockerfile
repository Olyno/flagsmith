# Your usual Flagsmith release produces of a number of shippable Docker images:

# - Private cloud: API, Unified
# - SaaS: API
# - Open Source: API, Frontend, Unified

# This Dockerfile is meant to build all of the above via composable, interdependent stages.
# The goal is to have as DRY as possible build for all the targets.

# Usage Examples

# Build an Open Source API image:
# $ docker build -t flagsmith-api:dev --target oss-api .

# Build an Open Source Unified image:
# (`oss-unified` stage is the default one, so there's no need to specify a target stage)
# $ docker build -t flagsmith:dev .

# Build a SaaS API image:
# $ GH_TOKEN=$(gh auth token) docker build -t flagsmith-saas-api:dev --target saas-api \
#     --secret="id=sse_pgp_pkey,src=./sse_pgp_pkey.key"\
#     --secret="id=github_private_cloud_token,env=GH_TOKEN" .

# Build a Private Cloud Unified image:
# $ GH_TOKEN=$(gh auth token) docker build -t flagsmith-private-cloud:dev --target private-cloud-unified \
#     --secret="id=github_private_cloud_token,env=GH_TOKEN" .

# Table of Contents
# Stages are described as stage-name [dependencies]

# - Intermediary stages
# * build-node [node]
# * build-node-django [build-node]
# * build-node-selfhosted [build-node]
# * build-python [wolfi-base]
# * build-python-private [build-python]
# * api-runtime [wolfi-base]
# * api-runtime-private [api-runtime]

# - Internal stages
# * api-test [build-python]
# * api-private-test [build-python-private]

# - Target (shippable) stages
# * private-cloud-api [api-runtime-private, build-python-private]
# * private-cloud-unified [api-runtime-private, build-python-private, build-node-django]
# * saas-api [api-runtime-private, build-python-private]
# * oss-api [api-runtime, build-python]
# * oss-frontend [node:slim, build-node-selfhosted]
# * oss-unified [api-runtime, build-python, build-node-django]

ARG CI_COMMIT_SHA=dev

# Pin runtimes versions
ARG NODE_VERSION=22
ARG PYTHON_VERSION=3.13

# Pin base images for reproducibility and security
# wolfi-base digest from 2025-02-20
FROM public.ecr.aws/docker/library/node:${NODE_VERSION}-bookworm AS node
FROM cgr.dev/chainguard/wolfi-base@sha256:9925d3017788558fa8f27e8bb160b791e56202b60c91fbcc5c867de3175986c8 AS wolfi-base

# Python environment variables to reduce image size and improve performance
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# - Intermediary stages
# * build-node
FROM node AS build-node

# Copy the files required to install npm packages
WORKDIR /build
COPY frontend/package.json frontend/package-lock.json frontend/.npmrc ./frontend/.nvmrc ./frontend/
COPY frontend/bin/ ./frontend/bin/
COPY frontend/env/ ./frontend/env/

ARG ENV=selfhosted
# Skip postinstall for free-email-domains to avoid network timeout in Docker builds.
# This package fetches remote data during install which often times out in Docker.
# Use cache mount for npm to speed up rebuilds.
RUN --mount=type=cache,target=/root/.npm \
    cd frontend && \
    echo "//registry.npmjs.org/:_authToken=${NPM_TOKEN}" >> .npmrc 2>/dev/null || true && \
    npm config set ignore-scripts true && \
    ENV=${ENV} npm ci --quiet --production && \
    npm config set ignore-scripts false && \
    # Manually run the env script to generate common/project.js
    node ./bin/env.js

COPY frontend /build/frontend

# * build-node-django [build-node]
FROM build-node AS build-node-django

RUN mkdir /build/api && cd frontend && npm run bundledjango

# * build-node-selfhosted [build-node]
FROM build-node AS build-node-selfhosted

RUN cd frontend && npm run bundle

# * build-python
FROM wolfi-base AS build-python
WORKDIR /build

ARG PYTHON_VERSION
RUN apk add build-base linux-headers curl git \
  python-${PYTHON_VERSION} \
  python-${PYTHON_VERSION}-dev \
  py${PYTHON_VERSION}-pip

COPY api/pyproject.toml api/poetry.lock api/Makefile ./
ENV POETRY_VIRTUALENVS_IN_PROJECT=true \
  POETRY_VIRTUALENVS_OPTIONS_ALWAYS_COPY=true \
  POETRY_VIRTUALENVS_OPTIONS_NO_PIP=true \
  POETRY_VIRTUALENVS_OPTIONS_NO_SETUPTOOLS=true \
  POETRY_HOME=/opt/poetry \
  PATH="/opt/poetry/bin:$PATH"
# Use cache mount for pip to speed up rebuilds and clean cache afterward to reduce image size
RUN --mount=type=cache,target=/root/.cache/pip \
    make install opts='--without dev' && \
    pip cache purge 2>/dev/null || true && \
    # Clean up unnecessary files from installed packages
    find /build/.venv/lib -type d \( \
        -name "tests" -o -name "test" -o -name "docs" -o -name "doc" -o \
        -name "examples" -o -name "demo" -o -name "demos" -o -name "benchmarks" \
    \) -exec rm -rf {} + 2>/dev/null || true && \
    find /build/.venv/lib -type f \( \
        -name "*.so.debug" -o -name "*.a" -o -name "*.c" -o -name "*.h" -o \
        -name "*.pyx" -o -name "*.pxd" -o -name "LICENSE*" -o -name "*.md" \
    \) -delete 2>/dev/null || true

# * build-python-private [build-python]
FROM build-python AS build-python-private

# Authenticate git with token, install private Python dependencies,
# and integrate private modules
ARG SAML_REVISION
ARG RBAC_REVISION
ARG WITH="saml,auth-controller,ldap,workflows,licensing,release-pipelines"
# Use cache mount for pip and clean up git credentials after use
RUN --mount=type=secret,id=github_private_cloud_token \
    --mount=type=cache,target=/root/.cache/pip \
    echo "https://$(cat /run/secrets/github_private_cloud_token):@github.com" > ${HOME}/.git-credentials && \
    git config --global credential.helper store && \
    make install-packages opts='--without dev --with ${WITH}' && \
    pip cache purge 2>/dev/null || true && \
    make install-private-modules && \
    rm -f ${HOME}/.git-credentials && \
    git config --global --unset credential.helper 2>/dev/null || true

# * api-runtime
FROM wolfi-base AS api-runtime

# Install Python only (no pip) and make it available to venv entrypoints
ARG PYTHON_VERSION
RUN apk add --no-cache python-${PYTHON_VERSION} && \
    mkdir -p /build/ && ln -s /usr/local/ /build/.venv

WORKDIR /app

COPY api /app/
COPY .release-please-manifest.json /app/.versions.json

ARG PROMETHEUS_MULTIPROC_DIR="/tmp/prometheus"
ARG ACCESS_LOG_LOCATION="/dev/null"
ENV ACCESS_LOG_LOCATION=${ACCESS_LOG_LOCATION} \
    PROMETHEUS_MULTIPROC_DIR=${PROMETHEUS_MULTIPROC_DIR} \
    DJANGO_SETTINGS_MODULE=app.settings.production \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

ARG CI_COMMIT_SHA
RUN echo ${CI_COMMIT_SHA} > /app/CI_COMMIT_SHA && \
  mkdir -p ${PROMETHEUS_MULTIPROC_DIR} && \
  chown nobody ${PROMETHEUS_MULTIPROC_DIR}

EXPOSE 8000

ENTRYPOINT ["/app/scripts/run-docker.sh"]

CMD ["migrate-and-serve"]

HEALTHCHECK --interval=2s --timeout=2s --retries=3 --start-period=20s \
  CMD flagsmith healthcheck tcp

# * api-runtime-private [api-runtime]
FROM api-runtime AS api-runtime-private

# Install SAML binary dependency
RUN apk add xmlsec

# - Internal stages
# * api-test [build-python]
FROM build-python AS api-test

COPY api /build/

RUN --mount=type=cache,target=/root/.cache/pip \
    make install-packages opts='--with dev' && \
    pip cache purge 2>/dev/null || true

CMD ["make", "test"]

# * api-private-test [build-python-private]
FROM build-python-private AS api-private-test

COPY api /build/

RUN --mount=type=cache,target=/root/.cache/pip \
    make install-packages opts='--with dev' && \
    pip cache purge 2>/dev/null || true && \
    make integrate-private-tests && \
    git config --global --unset credential.helper && \
    rm -f ${HOME}/.git-credentials

CMD ["make", "test"]

# - Target (shippable) stages
# * private-cloud-api [api-runtime-private, build-python-private]
FROM api-runtime-private AS private-cloud-api

COPY --from=build-python-private /build/.venv/ /usr/local/

# Collect static files and aggressively clean up to reduce image size
RUN python manage.py collectstatic --no-input && \
    # Remove Python cache files
    find /usr/local -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true && \
    find /usr/local -type f -name "*.pyc" -delete 2>/dev/null || true && \
    find /app -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true && \
    find /app -type f -name "*.pyc" -delete 2>/dev/null || true && \
    # Remove test files from app (shouldn't be in production)
    rm -rf /app/tests /app/conftest.py 2>/dev/null || true && \
    # Remove source maps from static files (not needed in production, saves ~27MB)
    find /app/static -name "*.map" -delete 2>/dev/null || true && \
    # Remove unnecessary files from Python packages
    find /usr/local/lib -type d \( \
        -name "tests" -o \
        -name "test" -o \
        -name "docs" -o \
        -name "doc" -o \
        -name "examples" -o \
        -name "demo" -o \
        -name "demos" -o \
        -name "benchmarks" -o \
        -name "*.dist-info" \
    \) -exec rm -rf {} + 2>/dev/null || true && \
    # Remove unnecessary file types
    find /usr/local/lib -type f \( \
        -name "*.so.debug" -o \
        -name "*.a" -o \
        -name "*.c" -o \
        -name "*.h" -o \
        -name "*.pyx" -o \
        -name "*.pxd" -o \
        -name "LICENSE*" -o \
        -name "COPYING*" -o \
        -name "AUTHORS*" -o \
        -name "CHANGELOG*" -o \
        -name "NEWS*" -o \
        -name "README*" -o \
        -name "*.md" -o \
        -name "*.rst" -o \
        -name "*.txt" \
    \) -delete 2>/dev/null || true && \
    # Remove pip, wheel, setuptools from final image
    rm -rf /usr/local/bin/pip* /usr/local/bin/wheel /usr/local/bin/easy_install* 2>/dev/null || true && \
    rm -rf /usr/local/lib/python*/site-packages/pip /usr/local/lib/python*/site-packages/wheel 2>/dev/null || true && \
    touch ./ENTERPRISE_VERSION

USER nobody

# * private-cloud-unified [api-runtime-private, build-python-private, build-node-django]
FROM api-runtime-private AS private-cloud-unified

COPY --from=build-python-private /build/.venv/ /usr/local/
COPY --from=build-node-django /build/api/ /app/

# Collect static files and clean up Python cache to reduce image size
RUN python manage.py collectstatic --no-input && \
    find /usr/local -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true && \
    find /usr/local -type f -name "*.pyc" -delete 2>/dev/null || true && \
    find /app -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true && \
    find /app -type f -name "*.pyc" -delete 2>/dev/null || true && \
    touch ./ENTERPRISE_VERSION

USER nobody

# * saas-api [api-runtime-private, build-python-private]
FROM api-runtime-private AS saas-api

# Install GnuPG and import private key, then remove it to reduce image size
RUN --mount=type=secret,id=sse_pgp_pkey \
    apk add --no-cache gpg gpg-agent && \
    gpg --import /run/secrets/sse_pgp_pkey && \
    mv /root/.gnupg/ /app/ && \
    chown -R nobody /app/.gnupg/ && \
    apk del gpg gpg-agent 2>/dev/null || true

COPY --from=build-python-private /build/.venv/ /usr/local/

# Collect static files and aggressively clean up to reduce image size
RUN python manage.py collectstatic --no-input && \
    # Remove Python cache files
    find /usr/local -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true && \
    find /usr/local -type f -name "*.pyc" -delete 2>/dev/null || true && \
    find /app -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true && \
    find /app -type f -name "*.pyc" -delete 2>/dev/null || true && \
    # Remove test files from app (shouldn't be in production)
    rm -rf /app/tests /app/conftest.py 2>/dev/null || true && \
    # Remove source maps from static files (not needed in production, saves ~27MB)
    find /app/static -name "*.map" -delete 2>/dev/null || true && \
    # Remove unnecessary files from Python packages
    find /usr/local/lib -type d \( \
        -name "tests" -o \
        -name "test" -o \
        -name "docs" -o \
        -name "doc" -o \
        -name "examples" -o \
        -name "demo" -o \
        -name "demos" -o \
        -name "benchmarks" -o \
        -name "*.dist-info" \
    \) -exec rm -rf {} + 2>/dev/null || true && \
    # Remove unnecessary file types
    find /usr/local/lib -type f \( \
        -name "*.so.debug" -o \
        -name "*.a" -o \
        -name "*.c" -o \
        -name "*.h" -o \
        -name "*.pyx" -o \
        -name "*.pxd" -o \
        -name "LICENSE*" -o \
        -name "COPYING*" -o \
        -name "AUTHORS*" -o \
        -name "CHANGELOG*" -o \
        -name "NEWS*" -o \
        -name "README*" -o \
        -name "*.md" -o \
        -name "*.rst" -o \
        -name "*.txt" \
    \) -delete 2>/dev/null || true && \
    # Remove pip, wheel, setuptools from final image
    rm -rf /usr/local/bin/pip* /usr/local/bin/wheel /usr/local/bin/easy_install* 2>/dev/null || true && \
    rm -rf /usr/local/lib/python*/site-packages/pip /usr/local/lib/python*/site-packages/wheel 2>/dev/null || true && \
    touch ./SAAS_DEPLOYMENT

USER nobody

# * oss-api [api-runtime, build-python]
FROM api-runtime AS oss-api

COPY --from=build-python /build/.venv/ /usr/local/

# Collect static files and aggressively clean up to reduce image size
RUN python manage.py collectstatic --no-input && \
    # Remove Python cache files
    find /usr/local -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true && \
    find /usr/local -type f -name "*.pyc" -delete 2>/dev/null || true && \
    find /app -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true && \
    find /app -type f -name "*.pyc" -delete 2>/dev/null || true && \
    # Remove test files from app (shouldn't be in production)
    rm -rf /app/tests /app/conftest.py 2>/dev/null || true && \
    # Remove source maps from static files (not needed in production, saves ~27MB)
    find /app/static -name "*.map" -delete 2>/dev/null || true && \
    # Remove unnecessary files from Python packages
    find /usr/local/lib -type d \( \
        -name "tests" -o \
        -name "test" -o \
        -name "docs" -o \
        -name "doc" -o \
        -name "examples" -o \
        -name "demo" -o \
        -name "demos" -o \
        -name "benchmarks" -o \
        -name "*.dist-info" \
    \) -exec rm -rf {} + 2>/dev/null || true && \
    # Remove unnecessary file types
    find /usr/local/lib -type f \( \
        -name "*.so.debug" -o \
        -name "*.a" -o \
        -name "*.c" -o \
        -name "*.h" -o \
        -name "*.pyx" -o \
        -name "*.pxd" -o \
        -name "LICENSE*" -o \
        -name "COPYING*" -o \
        -name "AUTHORS*" -o \
        -name "CHANGELOG*" -o \
        -name "NEWS*" -o \
        -name "README*" -o \
        -name "*.md" -o \
        -name "*.rst" -o \
        -name "*.txt" \
    \) -delete 2>/dev/null || true && \
    # Remove pip, wheel, setuptools from final image (already installed in virtualenv)
    rm -rf /usr/local/bin/pip* /usr/local/bin/wheel /usr/local/bin/easy_install* 2>/dev/null || true && \
    rm -rf /usr/local/lib/python*/site-packages/pip /usr/local/lib/python*/site-packages/wheel 2>/dev/null || true

USER nobody

# * oss-frontend [build-node-selfhosted]
# Use minimal Wolfi with node for frontend runtime
FROM wolfi-base AS oss-frontend

ARG NODE_VERSION
RUN apk add --no-cache nodejs-${NODE_VERSION}

WORKDIR /srv/bt

# Copy only the built frontend assets with proper ownership
COPY --from=build-node-selfhosted --chown=nobody:nobody /build/frontend/ /srv/bt/

# Clean up unnecessary files from node_modules to reduce image size
RUN find /srv/bt/node_modules -type d \( \
    -name "docs" -o \
    -name "test" -o \
    -name "tests" -o \
    -name "__tests__" -o \
    -name "examples" -o \
    -name "*.d.ts" -o \
    -name ".github" -o \
    -name ".git" \
    \) -exec rm -rf {} + 2>/dev/null || true && \
    find /srv/bt/node_modules -type f \( \
    -name "*.md" -o \
    -name "LICENSE" -o \
    -name "LICENSE.md" -o \
    -name "CHANGELOG*" -o \
    -name ".editorconfig" -o \
    -name ".eslintrc*" -o \
    -name ".prettierrc*" -o \
    -name "tsconfig.json" -o \
    -name "*.map" \
    \) -delete 2>/dev/null || true

ENV NODE_ENV=production

ARG CI_COMMIT_SHA
RUN echo ${CI_COMMIT_SHA} > /srv/bt/CI_COMMIT_SHA
COPY .release-please-manifest.json /srv/bt/.versions.json

EXPOSE 8080

USER nobody

CMD ["node", "./api/index.js"]

# * oss-unified [api-runtime, build-python, build-node-django]
FROM api-runtime AS oss-unified

COPY --from=build-python /build/.venv/ /usr/local/
COPY --from=build-node-django /build/api/ /app/

# Collect static files and aggressively clean up to reduce image size
RUN python manage.py collectstatic --no-input && \
    # Remove Python cache files
    find /usr/local -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true && \
    find /usr/local -type f -name "*.pyc" -delete 2>/dev/null || true && \
    find /app -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true && \
    find /app -type f -name "*.pyc" -delete 2>/dev/null || true && \
    # Remove test files from app (shouldn't be in production)
    rm -rf /app/tests /app/conftest.py 2>/dev/null || true && \
    # Remove source maps from static files (not needed in production, saves ~27MB)
    find /app/static -name "*.map" -delete 2>/dev/null || true && \
    # Remove unnecessary files from Python packages
    find /usr/local/lib -type d \( \
        -name "tests" -o \
        -name "test" -o \
        -name "docs" -o \
        -name "doc" -o \
        -name "examples" -o \
        -name "demo" -o \
        -name "demos" -o \
        -name "benchmarks" -o \
        -name "*.dist-info" \
    \) -exec rm -rf {} + 2>/dev/null || true && \
    # Remove unnecessary file types
    find /usr/local/lib -type f \( \
        -name "*.so.debug" -o \
        -name "*.a" -o \
        -name "*.c" -o \
        -name "*.h" -o \
        -name "*.pyx" -o \
        -name "*.pxd" -o \
        -name "LICENSE*" -o \
        -name "COPYING*" -o \
        -name "AUTHORS*" -o \
        -name "CHANGELOG*" -o \
        -name "NEWS*" -o \
        -name "README*" -o \
        -name "*.md" -o \
        -name "*.rst" -o \
        -name "*.txt" \
    \) -delete 2>/dev/null || true && \
    # Remove pip, wheel, setuptools from final image (already installed in virtualenv)
    rm -rf /usr/local/bin/pip* /usr/local/bin/wheel /usr/local/bin/easy_install* 2>/dev/null || true && \
    rm -rf /usr/local/lib/python*/site-packages/pip /usr/local/lib/python*/site-packages/wheel 2>/dev/null || true

USER nobody
