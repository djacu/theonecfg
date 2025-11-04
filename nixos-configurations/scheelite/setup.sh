#!/usr/bin/env bash

set -e
set -u
set -o pipefail
set -x

# shellcheck disable=SC2034
MNT=$(mktemp -d)
# shellcheck disable=SC1091
source ./partition-root.sh
# shellcheck disable=SC1091
source ./partition-tank.sh
