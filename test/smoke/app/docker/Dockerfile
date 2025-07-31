ARG UBUNTU_BASE_IMAGE=ubuntu:latest
FROM ${UBUNTU_BASE_IMAGE}

ARG APP_PORT=8080
ARG APP_USER=appuser
ARG APP_GROUP=appgroup
ARG UID=1000
ARG GID=1000

ENV DEBIAN_FRONTEND=noninteractive
ENV APP_PORT=${APP_PORT}

# install packages
RUN apt-get update && \
    apt-get upgrade --assume-yes && \
    apt-get install --assume-yes --no-install-recommends \
        ca-certificates \
        nginx \
        fcgiwrap \
        spawn-fcgi \
        dumb-init \
        curl \
        wget \
        gettext-base \
        && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# create application group and user
RUN if ! getent group | cut -d: -f3 | grep -q "^${GID}$" > /dev/null 2>&1; then \
      groupadd --gid "${GID}" "${APP_GROUP}"; fi && \
    if ! getent passwd | cut -d: -f3 | grep -q "^${UID}$" > /dev/null 2>&1; then \
      useradd --uid "${UID}" --gid "${GID}" --create-home "${APP_USER}"; fi

# create application directories
RUN mkdir -p /opt/app/www /opt/app/conf /opt/app/run

# copy entrypoint, start scripts and application distribution
COPY docker/docker-entrypoint.sh /opt/app/
COPY docker/docker-start.sh /opt/app/
COPY server.txt /opt/app/conf/nginx.conf
COPY index.sh /opt/app/www/index.sh

# set ownership
RUN chown -R ${UID}:${GID} /opt/app

# switch to non-root user and set working directory
USER ${UID}:${GID}
WORKDIR /opt/app

# check availability of the service
HEALTHCHECK --interval=20s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1

# set entrypoint and default command
ENTRYPOINT ["/usr/bin/dumb-init", "--", "/opt/app/docker-entrypoint.sh"]
CMD ["/opt/app/docker-start.sh"]
