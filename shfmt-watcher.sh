#!/usr/bin/env bash

base="$(dirname "$(readlink -f "$0")")"

inotifywait -m -r \
	-e close_write \
	-e moved_to \
	--format '%w%f' \
	"$base/lib" \
	"$base/scripts" \
	"$base/main.sh" | while read -r file; do
	if [[ -f $file && $file =~ .sh ]]; then
		shfmt --write --simplify "$file"
	fi
done
