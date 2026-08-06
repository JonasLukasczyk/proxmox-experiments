FROM node:24-alpine

WORKDIR /app

# Install production dependencies before copying the source so Docker can cache
# the dependency layer when only application code changes.
COPY package.json ./
RUN npm install --omit=dev

COPY src ./src

# Drop root privileges before starting the application.
USER node

CMD ["npm", "start"]
