#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

######################################################################
# PY stage that simply does a pip install on our requirements
######################################################################
ARG PY_VER=3.6.9
FROM python:${PY_VER} AS superset-py

RUN mkdir /app \
        && apt-get update -y \
        && apt-get install -y --no-install-recommends \
            build-essential \
            default-libmysqlclient-dev \
            libpq-dev \
        && rm -rf /var/lib/apt/lists/*
### Requirments installation were removed from here coz there were deps on the superset files
### Alter solution would be copy everything to this container early on.

######################################################################
# Node stage to deal with static asset construction
######################################################################
FROM node:10-jessie AS superset-node

ARG NPM_BUILD_CMD="build"
ENV BUILD_CMD=${NPM_BUILD_CMD}

# NPM ci first, as to NOT invalidate previous steps except for when package.json changes
RUN mkdir -p /app/superset-frontend
RUN mkdir -p /app/superset/assets
COPY ./docker/frontend-mem-nag.sh /
COPY ./superset-frontend/package* /app/superset-frontend/

## File had to be ran like that because of the '-' in the name
RUN chmod +x /frontend-mem-nag.sh
ENTRYPOINT ["/frontend-mem-nag.sh"]
RUN cd /app/superset-frontend \
        && npm ci

# Next, copy in the rest and let webpack do its thing
COPY ./superset-frontend /app/superset-frontend
# This is BY FAR the most expensive step (thanks Terser!)
RUN cd /app/superset-frontend \
        && npm run ${BUILD_CMD} \
        && rm -rf node_modules


######################################################################
# Final lean image...
######################################################################
ARG PY_VER=3.6.9
FROM python:${PY_VER} AS lean

COPY docker/docker_init.sh /app/
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    FLASK_ENV=production \
    FLASK_APP="superset.app:create_app()" \
    PYTHONPATH="/app/pythonpath" \
    SUPERSET_HOME="/app/superset_home" \
    SUPERSET_PORT=8080

## Had to add libsasl2-dev to install sassl
RUN useradd --user-group --no-create-home --no-log-init --shell /bin/bash superset \
        && mkdir -p ${SUPERSET_HOME} ${PYTHONPATH} \
        && apt-get update -y \
        && apt-get install -y --no-install-recommends \
            build-essential \
            default-libmysqlclient-dev \
            libpq-dev \
            libsasl2-dev \
        && rm -rf /var/lib/apt/lists/*

# Copying site-packages doesn't move the CLIs, so let's copy them one by one
COPY --from=superset-py /usr/local/lib/python3.6/site-packages/ /usr/local/lib/python3.6/site-packages/
## Had to move the copy of gunicorn from here to later as we moved the requirements installation
COPY --from=superset-node /app/superset/static/assets /app/superset/static/assets
COPY --from=superset-node /app/superset-frontend /app/superset-frontend

## Install Requirments + Superset
COPY superset /app/superset
COPY setup.py MANIFEST.in README.md /app/

# We just wanna install requirements, which will allow us to utilize the cache
# in order to only build if and only if requirements change
RUN mkdir -p /app/requirements/
COPY ./requirements/*.txt /app/requirements/
COPY ./docker/requirements-extra.txt /app/requirements/
RUN cd /app \
        && pip install --no-cache -r requirements/local.txt \
        && pip install --no-cache -r requirements/requirements-extra.txt

RUN cd /app \
        && chown -R superset:superset * \
        && pip install -e .

#Those Are moved from Line 83 as we need to install gunicorn first
RUN cp -R /usr/local/bin/gunicorn /usr/local/bin/celery /usr/local/bin/flask /usr/bin/


COPY docker/docker_entrypoint.sh /usr/bin/

WORKDIR /app

USER superset

HEALTHCHECK CMD ["curl", "-f", "http://localhost:8088/health"]

EXPOSE ${SUPERSET_PORT}

ENTRYPOINT ["/usr/bin/docker_entrypoint.sh"]

######################################################################
# Dev image...
######################################################################
FROM lean AS dev

RUN mkdir -p /app/requirements/
COPY ./requirements/*.txt  /app/requirements/

USER root
# Cache everything for dev purposes...
RUN cd /app \
    && pip install --ignore-installed -e . \
    && pip install --ignore-installed -r requirements/local.txt || true
USER superset
