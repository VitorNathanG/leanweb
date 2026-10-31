FROM leanweb-check:lean-4.33.1@sha256:cff3da6cbea33731530b06148d0e0d470be5b6b5692b753efbe3d90a5b68725a
RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake ccache m4 pkg-config libuv1-dev libssl-dev time strace=6.1-0.1 \
    && rm -rf /var/lib/apt/lists/*
