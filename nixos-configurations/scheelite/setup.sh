#!/usr/bin/env bash

set -e
set -u
set -o pipefail
set -x

MNT=$(mktemp -d)
source ./partition-root.sh
source ./partition-tank.sh
