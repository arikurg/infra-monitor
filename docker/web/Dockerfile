# docker/web/Dockerfile
FROM nginx:1.27-alpine

# Static status page
COPY web/html/ /usr/share/nginx/html/

# Config template — the official entrypoint runs envsubst over /etc/nginx/templates/*.template
# at startup, substituting ${APP_HOST}/${APP_PORT} from the container env.
COPY web/default.conf.template /etc/nginx/templates/default.conf.template

EXPOSE 80
