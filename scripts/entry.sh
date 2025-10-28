#!/usr/bin/env bash
export FB_RUNNING_AS_SCRIPT=1
thisFile="$(readlink -f "$0")"
export REPO_DIR="$(cd "$(dirname "${thisFile}")/.." && echo "$PWD")"
source "${REPO_DIR}/main.sh" || exit 1
scr_name="$(bash_basename $0)"
cmd="${scr_name//.sh/}"
if [[ $DEBUG == 1 ]]; then set -x; fi
$cmd "$@"
