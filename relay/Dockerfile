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
COPY package.json package-lock.json ./
# Only runtime deps; skips devDependencies.
RUN npm ci --omit=dev && npm cache clean --force
COPY --from=build /app/dist ./dist
COPY web ./web
EXPOSE 8787
CMD ["node", "dist/src/server.js"]
