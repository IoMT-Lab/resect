#!/bin/bash

# Check if docker-compose.yml exists in current directory
if [ ! -f "docker-compose.yml" ]; then
  pushd .. > /dev/null
  # Return to the original directory if we changed it
  trap 'popd > /dev/null 2>&1' EXIT
fi

docker compose --profile init --profile normal down -v --remove-orphans