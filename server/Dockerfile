FROM node:22-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build && npm prune --omit=dev

# Typst (compiles Claude's worksheets to PDF). Static musl binary, fetched in its own stage
# so curl/xz never end up in the runtime image.
FROM debian:bookworm-slim AS typst
ARG TARGETARCH
ARG TYPST_VERSION=v0.13.1
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
 && case "${TARGETARCH:-$(uname -m)}" in arm64|aarch64) arch=aarch64 ;; *) arch=x86_64 ;; esac \
 && curl -fsSL "https://github.com/typst/typst/releases/download/${TYPST_VERSION}/typst-${arch}-unknown-linux-musl.tar.xz" | tar xJ -C /tmp \
 && mv /tmp/typst-${arch}-unknown-linux-musl/typst /usr/local/bin/typst

FROM node:22-slim
# poppler-utils: pdfinfo/pdftoppm, for page counts and showing PDF pages to Claude.
RUN apt-get update && apt-get install -y --no-install-recommends fonts-dejavu-core poppler-utils && rm -rf /var/lib/apt/lists/*
COPY --from=typst /usr/local/bin/typst /usr/local/bin/typst
WORKDIR /app
ENV NODE_ENV=production DATA_DIR=/data PORT=8787
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY package.json ./
COPY public ./public
VOLUME /data
EXPOSE 8787
CMD ["node", "dist/index.js"]
