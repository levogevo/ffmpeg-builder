#!/usr/bin/env bash
cd "$(dirname "$(readlink -f $0)")/.."
export FB_RUNNING_AS_SCRIPT=1
. main.sh
scr_name="$(bash_basename $0)"
cmd="${scr_name//.sh}"
set -x
$cmd $@
