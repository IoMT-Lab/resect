#!/bin/bash

# Check if docker-compose.yml exists in current directory
if [ ! -f "docker-compose.yml" ]; then
  pushd .. > /dev/null
  # Return to the original directory if we changed it
  trap 'popd > /dev/null 2>&1' EXIT
fi

if [ ! -d "workdir" ]; then
  mkdir workdir
fi

docker compose --profile cli run --rm -e HOST_UID=`id -u` -e HOST_GID=`id -g` resect-cli