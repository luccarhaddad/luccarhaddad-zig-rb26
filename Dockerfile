FROM --platform=linux/amd64 alpine AS build_amd64

RUN apk add --no-cache curl xz

RUN curl -L https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz \
        -o /tmp/zig.tar.xz && \
    tar -xf /tmp/zig.tar.xz -C /usr/local && \
    mv /usr/local/zig-x86_64-linux-0.16.0 /usr/local/zig && \
    ln -s /usr/local/zig/zig /usr/local/bin/zig && \
    rm /tmp/zig.tar.xz

WORKDIR /app
COPY build.zig build.zig.zon ./
COPY src/ ./src/

RUN zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-musl

COPY references.bin ./

FROM busybox:1.37.0-musl
COPY --from=build_amd64 /app/zig-out/bin/luccahaddad_rb26 /luccahaddad_rb26
COPY --from=build_amd64 /app/references.bin /references.bin

EXPOSE 8080
CMD ["/luccahaddad_rb26"]
