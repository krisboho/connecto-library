# Headless KOReader (desktop Linux build) for exercising Shelf Sync end to end.
FROM debian:trixie-slim
ARG KOREADER_VERSION=v2026.07.1
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends ca-certificates curl xz-utils libsdl2-2.0-0 \
 && ARCH=$(dpkg --print-architecture | sed 's/amd64/x86_64/') \
 && curl -fsSL "https://github.com/koreader/koreader/releases/download/${KOREADER_VERSION}/koreader-linux-${ARCH}-${KOREADER_VERSION}.tar.xz" -o /tmp/ko.tar.xz \
 && tar -xJf /tmp/ko.tar.xz -C /usr \
 && rm -rf /tmp/ko.tar.xz /var/lib/apt/lists/*
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
