# This is the dockerfile spefically to be used with Render.com docker deployments. Do not use
# locally or in other environments as it will not be supported.


# Setup base image
FROM ubuntu:jammy-20230522 AS base

# Build arguments
ARG ARG_UID=1000
ARG ARG_GID=1000
ARG STORAGE_DIR

RUN if [ -z "$STORAGE_DIR" ]; then echo 'Environment variable STORAGE_DIR must be specified. Exiting.'; exit 1; fi

# Install system dependencies
RUN DEBIAN_FRONTEND=noninteractive apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends \
        curl gnupg libgfortran5 libgbm1 tzdata netcat \
        libasound2 libatk1.0-0 libc6 libcairo2 libcups2 libdbus-1-3 libexpat1 libfontconfig1 \
        libgcc1 libglib2.0-0 libgtk-3-0 libnspr4 libpango-1.0-0 libx11-6 libx11-xcb1 libxcb1 \
        libxcomposite1 libxcursor1 libxdamage1 libxext6 libxfixes3 libxi6 libxrandr2 libxrender1 \
        libxss1 libxtst6 ca-certificates fonts-liberation libappindicator1 libnss3 lsb-release \
        xdg-utils git build-essential ffmpeg && \
    mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_18.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && \
    apt-get install -yq --no-install-recommends nodejs && \
    curl -LO https://github.com/yarnpkg/yarn/releases/download/v1.22.19/yarn_1.22.19_all.deb \
        && dpkg -i yarn_1.22.19_all.deb \
        && rm yarn_1.22.19_all.deb

# Create a group and user with specific UID and GID
RUN groupadd -g $ARG_GID anythingllm && \
    useradd -u $ARG_UID -m -d /app -s /bin/bash -g anythingllm anythingllm && \
    mkdir -p /app/frontend/ /app/server/ /app/collector/ && chown -R anythingllm:anythingllm /app

# Copy docker helper scripts
COPY ./docker/render-entrypoint.sh /usr/local/bin/
COPY ./docker/docker-healthcheck.sh /usr/local/bin/
COPY --chown=anythingllm:anythingllm ./docker/.env.example /app/server/.env

# Ensure the scripts are executable
RUN chmod +x /usr/local/bin/render-entrypoint.sh && \
    chmod +x /usr/local/bin/docker-healthcheck.sh

USER anythingllm

WORKDIR /app

# Install frontend dependencies
FROM base as frontend-deps

COPY ./frontend/package.json ./frontend/yarn.lock ./frontend/
RUN cd ./frontend/ && yarn install  --network-timeout 100000 && yarn cache clean

# Install server dependencies
FROM base as server-deps
COPY ./server/package.json ./server/yarn.lock ./server/
RUN cd ./server/ && yarn install --production --network-timeout 100000 && yarn cache clean

# Compile Llama.cpp bindings for node-llama-cpp for this operating system.
USER root
RUN cd ./server && npx --no node-llama-cpp download
USER anythingllm

# Build the frontend
FROM frontend-deps as build-stage
COPY ./frontend/ ./frontend/
RUN cd ./frontend/ && yarn build && yarn cache clean

# Setup the server
FROM server-deps as production-stage
COPY --chown=anythingllm:anythingllm ./server/ ./server/

# Copy built static frontend files to the server public directory
COPY --from=build-stage /app/frontend/dist ./server/public

# Copy the collector
COPY --chown=anythingllm:anythingllm ./collector/ ./collector/

# Install collector dependencies
RUN cd /app/collector && yarn install --production --network-timeout 100000 && yarn cache clean

# Setup the environment
ENV NODE_ENV=production
ENV STORAGE_DIR=$STORAGE_DIR

# Expose the server port
EXPOSE 3001

# Setup the healthcheck
HEALTHCHECK --interval=1m --timeout=10s --start-period=1m \
  CMD /bin/bash /usr/local/bin/docker-healthcheck.sh || exit 1

# Run the server
ENTRYPOINT ["/bin/bash", "/usr/local/bin/render-entrypoint.sh"]
