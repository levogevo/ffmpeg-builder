#!/usr/bin/env bash
cd "$(dirname "$(readlink -f $0)")/.."
export FB_RUNNING_AS_SCRIPT=1
. main.sh || return 1
scr_name="$(bash_basename $0)"
cmd="${scr_name//.sh/}"
if [[ $DEBUG == 1 ]]; then set -x; fi
$cmd "$@"
