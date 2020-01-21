# This Dockerfile builds IPFS, tests it, and creates a minimal final stage with it

# IPFS version to be built
ARG VERSION=v0.4.22

# Target CPU archtecture of built IPFS binary
ARG ARCH

# Define default versions so that they aren't repreated throughout the file
ARG VER_GO=1.13
ARG VER_ALPINE=3.11

# Default user, and their home directory for the `final` stage
ARG USER=ipfs
ARG DIR=/data/

# There are two possible variants: build|nofuse, and they correspond directly to `Makefile` targets:
#   `nofuse` - only allow for API-level communication
#   `build` - enable mounting `/ipns/` & `/ipfs/`, and file system level interactions
ARG VARIANT=nofuse

# The level of testing to be performed before creating the `final` stage.  Can be set to: `none`, `simple`, `advanced`
ARG TEST_LEVEL=simple

# It's IPFS's Makefile configuration flag.  It's useful as we might want to sometimes test fuse as well
ARG TEST_NO_FUSE=1



#
## Prepare IPFS source for building:
#   * install dependencies
#   * Set Go's environment variables
#   * clone source
#   * verify source's signature
#   * prints environemnt details
#   * apply necessary fixes to go.mod, and print the difference
#
FROM golang:${VER_GO}-alpine${VER_ALPINE} AS preparer

# Provided by Docker by default
ARG TARGETVARIANT

# These two should only be set for cross-compilation
ARG GOARCH
ARG GOARM

# Capture ARGs defined globally
ARG VERSION
ARG USER
ARG DIR

# Only set GOOS if GOARCH is set
ENV GOOS ${GOARCH:+linux}

# If GOARM is not set, but TARGETVARIANT is set - hardcode GOARM to 6
ENV GOARM ${GOARM:-${TARGETVARIANT:+6}}

# Most dependencies are needed for tests
RUN apk add --no-cache  gcc  git  gnupg  libc-dev  make  upx

# NOTE: `adduser`, because tests fail when run as root
RUN adduser --disabled-password \
            --gecos "" \
            ${USER}

RUN mkdir -p  /go/src/
RUN chown -R ${USER}:${USER}  /go/src/

USER ${USER}

ENV KEYS 327B20CE21EA68CFA77486757C9232215899410C

# Try to fetch keys from keyservers listed below.  On first success terminate with `exit 0`.  If loop is not interrupted,
#   it means all attempts failed, and `exit 1` is called.
RUN for srv in  keyserver.ubuntu.com  hkp://p80.pool.sks-keyservers.net:80  ha.pool.sks-keyservers.net  keyserver.pgp.com  pgp.mit.edu; do \
        timeout 9s  gpg  --keyserver "${srv}"  --recv-key ${KEYS}  >/dev/null 2<&1 && \
            { echo "OK:  ${srv}" && exit 0; } || \
            { echo "ERR: ${srv} fail=$?"; } ; \
    done && exit 1

RUN gpg --list-keys && \
    gpg --list-keys ${KEYS}

# Fetch IPFS source code
RUN cd /go/src/ && \
    git clone  -b ${VERSION}  --depth=1  https://github.com/ipfs/go-ipfs.git .

WORKDIR /go/src/

# Verify that git tag contains a valid signature
RUN git verify-tag "${VERSION}"

RUN env && go version && go env

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

RUN go mod tidy

RUN git diff



#
## Perform NO TESTS whatsoever
#
FROM preparer AS test-none



#
## Perform UNIT TESTS only
#
FROM preparer AS test-simple

ARG TEST_NO_FUSE

RUN make test_go_short



#
## Perform UNIT & INTEGRATION TESTS
#
FROM preparer AS test-advanced

ARG USER
ARG TEST_NO_FUSE

# Switch to root to install all dependencies required by integration test suite
USER root
RUN apk add --no-cache  build-base  bash  coreutils  curl  grep  perl  psmisc  socat

# Switch back to $USER, as tests have to be run as non-root
USER ${USER}

ENV TEST_NO_DOCKER 1
ENV TEST_VERBOSE 1

# This also runs various integration tests
RUN make test_short



#
## This stage picks up whichever test level was selected, and produces the final binary at `/go/src/cmd/ipfs/ipfs`
#
FROM test-${TEST_LEVEL} AS build

ARG VARIANT

# Can be either `make build`, or `make nofuse`
RUN make ${VARIANT}

RUN upx -v ./cmd/ipfs/ipfs




#
## TODO: describe
#
# NOTE: `${ARCH:+${ARCH}/}` - if ARCH is set, append `/` to it, leave it empty otherwise
FROM ${ARCH:+${ARCH}/}alpine:${VER_ALPINE} AS final-common

ARG DIR

LABEL maintainer="Damian Mee (@meeDamian)"

# Copy the built binary
COPY  --from=build  /go/src/cmd/ipfs/ipfs  /usr/local/bin/

# Public ports (swarm TCP, web gateway, and swarm websockets respectively)
EXPOSE  4001  8080  8081

# Private port (daemon API)
EXPOSE  5001

# Pre-configure some parts of IPFS (logging level can be changed later at any time)
ENV IPFS_LOGGING=info

ENTRYPOINT ["ipfs"]




#
## TODO: describe how to run it
#       Alternative version;  with fuse
#
FROM final-common AS final-build

# TODO: figure out what `apk add fuse` does exactly, amd replicate it w/o `RUN`ning any commands

# TODO: temporary
ONBUILD RUN apk add --no-cache fuse
ONBUILD RUN echo user_allow_other >> /etc/fuse.conf
ONBUILD RUN ipfs init
ONBUILD RUN ipfs config --json Mounts.FuseAllowOther true

# Expose the volume containing the _internals_part of IPFS
VOLUME ${DIR}/.ipfs/

# Expose the volumes containing the file-system parts of what IPFS makes available
VOLUME /ipfs/
VOLUME /ipns/

ENTRYPOINT ["echo", "This variant has to be handled in a rather peculiar way.  For details see: URL"]
ONBUILD ENTRYPOINT ["ipfs"]

ONBUILD CMD ["daemon", "--init", "--migrate", "--mount"]




#
## This stage is necessary for cross-compilation (only possible if there's no `RUN`s in the `final` stage)
#   On a "fresh" Alpine base, it generates `/etc/{group,passwd,shadow}` files, that can later be copied into `final`
#
FROM alpine:${VER_ALPINE} AS perms

ARG USER
ARG DIR

# NOTE: Default GID == UID == 1000
RUN adduser --disabled-password \
            --home ${DIR} \
            --gecos "" \
            ${USER}

# Needed to prevent `VOLUME ${DIR}/.ipfs/` creating it with `root` as owner
USER ${USER}
RUN mkdir -p ${DIR}/.ipfs/



#
## TODO: describe
#       The default; nofuse
#
FROM final-common AS final

ARG USER
ARG DIR

# Copy only the relevant parts from the `perms` image
COPY  --from=perms /etc/group /etc/passwd /etc/shadow  /etc/

# From `perms`, copy *the contents* of `${DIR}` (ie. `.ipfs/`), and set correct owner for destination `${DIR}`
COPY  --from=perms --chown=${USER}:${USER} ${DIR}  ${DIR}

USER ${USER}

# Expose the volume containing the _internals_ of IPFS
VOLUME ${DIR}/.ipfs/

CMD ["daemon", "--init", "--migrate"]
