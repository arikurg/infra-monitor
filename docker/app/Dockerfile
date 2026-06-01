# docker/app/Dockerfile
FROM node:20-alpine

WORKDIR /opt/app

# Install deps first so this layer caches unless package.json changes
COPY app/package.json ./
RUN npm install --omit=dev

COPY app/server.js ./

# Run as the unprivileged user that ships with the node image
USER node

EXPOSE 3000
CMD ["node", "server.js"]
