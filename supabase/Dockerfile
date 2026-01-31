FROM node:22-alpine

RUN apk add --no-cache ca-certificates wget && update-ca-certificates

# install at build time
RUN npm i -g mcp-proxy @zeddotdev/postgres-context-server

EXPOSE 3333

# IMPORTANT: pass child command + args after `--` (no --args)
CMD ["sh","-lc","mcp-proxy --transport sse --host 0.0.0.0 --port 3333 -- postgres-context-server \"$DATABASE_URL\""]
