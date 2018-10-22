FROM crystallang/crystal
LABEL name="kgk"

ADD shard.yml /app/
ADD shard.lock /app/
WORKDIR /app
RUN shards install

ADD src /app/src
ADD local.yml /app/

RUN shards build

CMD /app/bin/kgk
