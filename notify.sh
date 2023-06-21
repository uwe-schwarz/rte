#!/usr/bin/env bash

# a simple notify script to send results to ntfy.sh
# 
# call via:
#   notify.sh "topic" "text"

# exit quietly if wrong number of arguments
if [ $# -lt 2 ]; then
  exit 0
fi

topic="$1"
shift

# call curl without any output
curl -s -o /dev/null -d "$*" "https://ntfy.sh/$topic"
