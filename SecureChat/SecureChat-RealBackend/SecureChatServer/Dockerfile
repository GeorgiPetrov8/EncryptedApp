# Zero third-party npm dependencies (see package.json) — this build stage
# exists only to keep the runtime image minimal, not to install anything.
FROM node:22-slim

WORKDIR /app

COPY package.json ./
COPY server.js ./
COPY src ./src

# Where the SQLite file lives; mounted as a volume in docker-compose.yml so
# data survives a container recreate.
RUN mkdir -p /app/data
VOLUME ["/app/data"]

ENV NODE_ENV=production
ENV PORT=8080
ENV DB_PATH=/app/data/securechat.sqlite

EXPOSE 8080

# Node's built-in test runner / healthcheck avoids needing curl in the image.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD node -e "fetch('http://127.0.0.1:8080/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "server.js"]
