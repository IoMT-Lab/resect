#!/bin/bash

# Check if compose.yml exists in current directory
if [ ! -f "compose.yml" ]; then
  pushd .. > /dev/null
  # Return to the original directory if we changed it
  trap 'popd > /dev/null 2>&1' EXIT
fi

docker compose run --rm cache-cleaner