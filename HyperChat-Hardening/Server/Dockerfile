FROM node:22-alpine

WORKDIR /app

# No `npm install` step: the server has no third-party dependencies
# (it uses Node's built-in node:sqlite, node:http2 and fetch).
COPY package.json server.js ./
COPY src ./src

RUN mkdir -p /app/data && chown -R node:node /app

USER node
ENV NODE_ENV=production
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||8080)+'/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "server.js"]
