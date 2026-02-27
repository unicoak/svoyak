FROM node:20-alpine AS build

WORKDIR /app/backend

COPY backend/package*.json ./
RUN npm ci

COPY backend/tsconfig.json ./
COPY backend/src ./src
COPY backend/migrations ./migrations

RUN npm run build
RUN npm prune --omit=dev

FROM node:20-alpine AS runtime

WORKDIR /app/backend
ENV NODE_ENV=production

COPY --from=build /app/backend/package*.json ./
COPY --from=build /app/backend/node_modules ./node_modules
COPY --from=build /app/backend/dist ./dist
COPY --from=build /app/backend/migrations ./migrations

EXPOSE 3000

CMD ["npm", "run", "start:with-migrate"]
