# IPFS version to be built
ARG VERSION=v0.4.22

# Target CPU archtecture of built IPFS binary
ARG ARCH=amd64

# The level of testing to be performed before creating the `final` stage.  Can be set to: `simple`, `advanced`
ARG TEST_LEVEL=simple

# Default user, and their home directory for the `final` stage
ARG USER=ipfs
ARG DIR=/data/

# Define default versions so that they don't have to be repreated throughout the file
ARG VER_GO=1.13
ARG VER_ALPINE=3.11

#
## This set of Docker stages, serves as a base for all cross-compilation targets.
#   `go-base` only defines `GOOS`, which is common to all other ARCH-specific stages.
#   Each supported CPU architecture defines it's own stage, which inherits from `go-base`, and sets up its own ENV VARs.
#
FROM golang:${VER_GO}-alpine${VER_ALPINE} AS go-base
ENV GOOS linux

FROM go-base AS amd64
ENV GOARCH amd64

FROM go-base AS arm64
ENV GOARCH arm64

FROM go-base AS arm32v6
ENV GOARCH arm
ENV GOARM 6

FROM go-base AS arm32v7
ENV GOARCH arm
ENV GOARM 7


#
## This stage prepares the environment for IPFS build:
#   * installs all deps & deps of tests
#   * creates & switches to a non-root user
#   * fetches GPG key to verify cloned source
#   * clones & actually verifies the source
#   * prints the details of the environment
#   * applies necessary fixes to go.mod, and prints the difference
#
FROM ${ARCH} AS prepare

ARG VERSION
ARG USER

# Most dependencies are needed for tests
RUN apk add --no-cache  build-base  bash  coreutils  curl  gnupg  grep  git  perl  psmisc  socat

# NOTE: `adduser`, because tests fail when run as root
RUN adduser --disabled-password \
            --home /ipfs/ \
            --gecos "" \
            ${USER}

# Switch to ${USER}, and homedir `/ipfs/`
# Note that's an ephemeral build stage so using `${DIR}` makes no sense
USER ${USER}
WORKDIR /ipfs/

RUN git clone  -b ${VERSION}  https://github.com/ipfs/go-ipfs.git

WORKDIR /ipfs/go-ipfs/

ENV KEY 327B20CE21EA68CFA77486757C9232215899410C

# Try to fetch keys from keyservers listed below.  On first success terminate with `exit 0`.  If loop is not interrupted,
#   it means all attempts failed, and `exit 1` is called.
RUN for SRV in keyserver.ubuntu.com  hkp://p80.pool.sks-keyservers.net:80  ha.pool.sks-keyservers.net  keyserver.pgp.com  pgp.mit.edu; do \
        timeout 9s  gpg  --keyserver "${SRV}"  --recv-key ${KEY}  >/dev/null 2<&1 && \
            { echo "OK:  ${SRV}" && exit 0; } || \
            { echo "ERR: ${SRV} fail=$?"; } ; \
    done && exit 1

RUN gpg --list-keys && \
    gpg --list-key ${KEY}

RUN git verify-tag ${VERSION}

RUN env
RUN go version
RUN go env

# NOTE: Fix as per https://github.com/ipfs/go-ipfs/issues/6795#issuecomment-571165734
RUN go mod edit \
    -replace github.com/go-critic/go-critic=github.com/go-critic/go-critic@v0.4.0 \
    -replace github.com/golangci/errcheck=github.com/golangci/errcheck@v0.0.0-20181223084120-ef45e06d44b6 \
    -replace github.com/golangci/go-tools=github.com/golangci/go-tools@v0.0.0-20190318060251-af6baa5dc196 \
    -replace github.com/golangci/gofmt=github.com/golangci/gofmt@v0.0.0-20181222123516-0b8337e80d98 \
    -replace github.com/golangci/gosec=github.com/golangci/gosec@v0.0.0-20190211064107-66fb7fc33547 \
    -replace github.com/golangci/lint-1=github.com/golangci/lint-1@v0.0.0-20190420132249-ee948d087217 \
    -replace mvdan.cc/unparam=mvdan.cc/unparam@v0.0.0-20190209190245-fbb59629db34 \
    -replace golang.org/x/xerrors=golang.org/x/xerrors@v0.0.0-20191204190536-9bdfabe68543

RUN git diff go.mod


#
## This stage picks up where `prepare` left off, and only runs simple Go tests
#
FROM prepare AS simple

# NOTE: we're building `nofuse`, so testing fuse is pointless
ENV TEST_NO_FUSE 1

RUN make test_go_short


#
## This stage picks up where `prepare` left off, and performs all kinds of tests
#
FROM prepare AS advanced

ENV TEST_NO_FUSE 1
ENV TEST_NO_DOCKER 1
ENV TEST_VERBOSE 1

# TODO: (?) only run tests when ${ARCH} == "amd64"
# TODO: Both of these crash when called directly, that's why it's split into individual calls below :/
#RUN make test
#RUN make test_short

# TODO: The following 4 lines are only needed, because direct `make test[_short]` fails…
RUN make deps
RUN make test_sharness_deps
RUN make test_go_expensive
RUN make test_sharness_short


#
## This stage picks up whichever test level was selected, and produces the final binary at `/bin/ipfs`
#
FROM ${TEST_LEVEL} AS build

# Same as `make build`, except no fuse
RUN make nofuse

# Finally, copy the built binary to `/bin/ipfs`
USER root
RUN mv ./cmd/ipfs/ipfs /bin/


#
## This stage is necessary for cross-compilation (only possible if there's no `RUN`s in the `final` stage)
#   On a "fresh" Alpine base, it generates `/etc/{group,passwd,shadow}` files, that can later be copied into `final`
FROM alpine:${VER_ALPINE} AS perms

ARG USER
ARG DIR

# NOTE: Default GID == UID == 1000
RUN adduser --disabled-password \
            --home ${DIR} \
            --gecos "" \
            ${USER}


#
## This is the final image that gets shipped to Docker Hub
#
FROM ${ARCH}/alpine:${VER_ALPINE} AS final

ARG USER
ARG DIR

LABEL maintainer="Damian Mee (@meeDamian)"

# Copy only the relevant parts from the `perms` image
COPY  --from=perms  /etc/group   /etc/
COPY  --from=perms  /etc/passwd  /etc/
COPY  --from=perms  /etc/shadow  /etc/

# Copy the built binary
COPY  --from=build  /bin/ipfs  /bin/

VOLUME ${DIR}

# Public ports (swarm TCP, web gateway, and swarm websockets respectively)
EXPOSE 4001 8080 8081

# Private port (daemon API)
EXPOSE 5001

USER ${USER}
WORKDIR ${DIR}

ENTRYPOINT ["ipfs"]

# TODO: Any CMD(?)
