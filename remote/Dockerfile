# Multi-stage build for the WispTerm Remote Console (Docker variant).
# This produces a standalone Node.js relay that mirrors the Cloudflare Worker.

FROM node:22-alpine AS build
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY . .

ARG WISPTERM_WEB_BUILD_TIME
RUN VITE_WISPTERM_WEB_BUILD_TIME="${WISPTERM_WEB_BUILD_TIME:-$(date '+%Y %m %d %H:%M')}" npm run build:docker

FROM node:22-alpine AS runtime
WORKDIR /app

ENV NODE_ENV=production
ENV PORT=8787
ENV HOST=0.0.0.0

COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY --from=build /app/dist ./dist
COPY --from=build /app/dist-server ./dist-server

USER node
EXPOSE 8787

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -q --spider http://127.0.0.1:8787/api/me || exit 1

CMD ["node", "dist-server/index.js"]
