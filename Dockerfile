LABEL name="kgk"
FROM alpine:edge

COPY local.yml /kgk/kgk.yml
COPY kgk.py /kgk/kgk.py
COPY requirements.txt /kgk/requirements.txt
COPY docker.sh /kgk/docker.sh

RUN ash /kgk/docker.sh
