#!/bin/sh
if [ $# != "1" ]
then
    echo "Usage: ./utils/releasetools/01_create_tarball.sh <version_tag>"
    exit 1
fi

TAG="$1" exec scripts/tarball.sh
