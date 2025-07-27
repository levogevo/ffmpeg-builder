#!/usr/bin/env bash
cd "$(dirname "$(readlink -f $0)")/.."
. main.sh
FB_RUNNING_AS_SCRIPT=1
scr_name="$(bash_basename $0)"
cmd="${scr_name//.sh/}"
$cmd $@
