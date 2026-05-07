FROM registry.fedoraproject.org/fedora:latest AS build
RUN dnf install -y gcc git util-linux && \
    git clone https://github.com/V4bel/dirtyfrag.git /build/dirtyfrag && \
    cd /build/dirtyfrag && \
    gcc -O0 -Wall -o exp exp.c -lutil

FROM registry.fedoraproject.org/fedora:latest
RUN dnf install -y util-linux && dnf clean all
COPY --from=build /build/dirtyfrag/exp /usr/local/bin/dirtyfrag
USER 1000
ENTRYPOINT ["/usr/local/bin/dirtyfrag"]
