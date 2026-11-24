ARG NGINX_IMAGE=dhi.io/nginx:1.31-alpine

FROM --platform=$BUILDPLATFORM ${NGINX_IMAGE} AS verify
COPY site/ /site/
COPY nginx.conf /etc/nginx/conf.d/default.conf
RUN test -s /site/framework-views.json && nginx -t

FROM ${NGINX_IMAGE}
COPY --from=verify /site/ /usr/share/nginx/html/
COPY --from=verify /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf
