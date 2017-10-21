FROM alpine:edge
LABEL name="kgk"

COPY local.yml /kgk/kgk.yml
COPY kgk.py /kgk/kgk.py
COPY requirements.txt /kgk/requirements.txt
COPY docker.sh /kgk/docker.sh

RUN ash /kgk/docker.sh
CMD python3 /kgk/kgk.py /kgk/kgk.yml
