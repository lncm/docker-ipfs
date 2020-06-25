#!/usr/bin/env bash

set -eo pipefail

SLUG=$1
VERSION=$2
FLAVOR=$3
SHORT_VERSION=${4:-$VERSION}

BASE="$SLUG:$VERSION-$FLAVOR"

IMAGE_AMD64="$BASE-amd64"
IMAGE_ARM32v6="$BASE-arm32v6"
IMAGE_ARM32v7="$BASE-arm32v7"
IMAGE_ARM64v8="$BASE-arm64v8"

MANIFEST="$SLUG:$SHORT_VERSION"

echo "Creating ${MANIFEST}…"

docker -D manifest create "$MANIFEST"  "$IMAGE_AMD64"  "$IMAGE_ARM32v6"  "$IMAGE_ARM32v7"  "$IMAGE_ARM64v8"
docker manifest annotate  "$MANIFEST"  "$IMAGE_ARM32v6"  --os linux  --arch arm   --variant v6
docker manifest annotate  "$MANIFEST"  "$IMAGE_ARM32v7"  --os linux  --arch arm   --variant v7
docker manifest annotate  "$MANIFEST"  "$IMAGE_ARM64v8"  --os linux  --arch arm64 --variant v8
docker manifest push      "$MANIFEST"

docker manifest inspect   "$MANIFEST" | jq '.'

echo
