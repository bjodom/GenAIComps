# Copyright (C) 2024 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

FROM python:3.11-slim

ARG ARCH="cpu"  # Set this to "cpu" or "gpu"

RUN useradd -m -s /bin/bash user && \
    mkdir -p /home/user && \
    chown -R user /home/user/

RUN apt-get update -y && apt-get install -y --no-install-recommends --fix-missing \
    curl \
    libgl1-mesa-glx \
    libjemalloc-dev

COPY comps /home/user/comps

RUN pip install --no-cache-dir --upgrade pip setuptools && \
    if [ ${ARCH} = "cpu" ]; then \
      pip install --no-cache-dir --extra-index-url https://download.pytorch.org/whl/cpu -r /home/user/comps/web_retrievers/src/requirements.txt; \
    else \
      pip install --no-cache-dir -r /home/user/comps/web_retrievers/src/requirements.txt; \
    fi

ENV PYTHONPATH=$PYTHONPATH:/home/user

USER user

WORKDIR /home/user/comps/web_retrievers/src

ENTRYPOINT ["python", "opea_web_retrievers_microservice.py"]
