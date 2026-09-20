# Relay server — production image for Fly.io
# Multi-stage: build TypeScript -> dist, then ship a slim runtime with prod deps only.

FROM node:20-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
COPY web ./web
RUN npm run build

FROM node:20-alpine AS runtime
ENV NODE_ENV=production
ENV HOST=0.0.0.0
WORKDIR /app
# Security review 2026-09-20 (L7): the runtime ran as root. The relay is a
# public endpoint that parses attacker-controlled frames, so it drops to
# the image's own unprivileged `node` user. Every COPY below is chowned to
# it and the workdir is created owned by it, so nothing has to be writable
# by root at runtime; the relay holds no state on disk anyway.
RUN mkdir -p /app && chown node:node /app
USER node
COPY --chown=node:node package.json package-lock.json ./
# Only runtime deps; skips devDependencies.
RUN npm ci --omit=dev && npm cache clean --force
COPY --from=build --chown=node:node /app/dist ./dist
COPY --chown=node:node web ./web
# 8787 is above 1024, so binding it needs no privilege.
EXPOSE 8787
CMD ["node", "dist/src/server.js"]
