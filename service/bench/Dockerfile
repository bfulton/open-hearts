# The backup jurors (service/bin/juror.dart), as Cloudflare
# runs them: service/do/bench.mjs starts this when a table calls for a
# juror and nobody is there, and stops it when the jurors have gone
# quiet. Built from what build.sh stages; run ./build.sh first. The base
# is Canonical's own Ubuntu image from the AWS public registry, which
# does not rate-limit a shared address the way Docker Hub does.
FROM public.ecr.aws/ubuntu/ubuntu:24.04
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /bench
COPY stage/ /bench/
EXPOSE 8080
# The relays come from the environment the Worker starts it with; the
# defaults are production's (app/lib/net/relays.dart).
ENV OH_RELAYS="wss://relay.openhearts.game/{tag}"
ENV OH_PRESENCE_RELAYS="wss://relay.openhearts.game/{tag}"
CMD ["sh", "-c", "exec /bench/juror --relay \"$OH_RELAYS\" --presence \"$OH_PRESENCE_RELAYS\" --port 8080"]
