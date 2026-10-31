# The house (service/bin/house.dart), as Cloudflare runs it:
# service/do/bench.mjs starts this when a sealed table wants the house
# and it is not there, and stops it once it has gone quiet. Built from
# what build.sh stages; run ./build.sh first. The base
# is Canonical's own Ubuntu image from the AWS public registry, which
# does not rate-limit a shared address the way Docker Hub does.
FROM public.ecr.aws/ubuntu/ubuntu:24.04
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /bench
COPY stage/ /bench/
EXPOSE 8080
# The relay comes from the environment the Worker starts it with, and
# the house's secret with it; the default is production's
# (app/lib/net/relays.dart).
ENV OH_RELAYS="wss://relay.openhearts.game/{tag}"
CMD ["sh", "-c", "exec /bench/house --relay \"$OH_RELAYS\" --port 8080"]
