set shell := ["bash", "-c"]

export HOST_UID := `id -u`
export HOST_GID := `id -g`
export WAYLAND_DISPLAY := env('WAYLAND_DISPLAY', 'wayland-0')
export XDG_RUNTIME_DIR := env('XDG_RUNTIME_DIR', f'/run/user/{{HOST_UID}}')

export ALLOW_BUILD := '0'

PROJECT_DIR := `pwd`
DOCKER_DIR := '`pwd`/docker'
COMPOSE := 'docker compose'

INSTALL_PROFILE := '--profile init'
RUN_PROFILE := '--profile normal'
ALL_PROFILES := f'{{INSTALL_PROFILE}} {{RUN_PROFILE}}'

alias cli := run_cli
alias gui := run_gui
alias vnc := run_vnc

#===============================================================================
# Setup Recipes
#===============================================================================

[group('Setup')]
[doc('Execute first-time setup tasks, such as downloading models and initializing the database.')]
install:
    {{COMPOSE}} {{ALL_PROFILES}} run --rm ollama-init

[group('Setup')]
[doc('Create the working directory that will be mounted into the container, if it does not exist.')]
@create_workdir:
    mkdir -p workdir

#===============================================================================
# Teardown Recipes
#===============================================================================

[group('Teardown')]
[doc('Stop all running containers.')]
stop:
    {{COMPOSE}} {{ALL_PROFILES}} stop

[group('Teardown')]
[doc('Clean all databases and caches.')]
[confirm("Are you sure you want to clean? This will remove any databases and caches.")]
clean:
    {{COMPOSE}} run --rm cache-cleaner

[group('Teardown')]
[doc('Uninstall all containers and volumes, including the one used for model storage.')]
[confirm("Are you sure you want to uninstall? This will remove all containers and volumes.")]
uninstall:
    {{COMPOSE}} {{ALL_PROFILES}} down -v --remove-orphans

#===============================================================================
# Run Recipes
#===============================================================================

[group('Run')]
[doc('Run the CLI version of Resect.')]
run_cli: create_workdir
    #!/bin/bash
    set -euxo pipefail
    export INTERNAL_ENV_FILE={{DOCKER_DIR}}/non_gui.env
    {{COMPOSE}} {{RUN_PROFILE}} run --rm resect cli

[group('Run')]
[doc('Run the GUI version of Resect locally.')]
[no-exit-message]
run_gui: create_workdir
    #!/bin/bash
    set -euxo pipefail
    export INTERNAL_ENV_FILE={{DOCKER_DIR}}/gui.env
    {{COMPOSE}} {{RUN_PROFILE}} run --rm resect gui

[group('Run')]
[doc('Run the GUI version of Resect in a VNC session.')]
run_vnc: create_workdir
    #!/bin/bash
    set -euxo pipefail
    export INTERNAL_ENV_FILE={{DOCKER_DIR}}/non_gui.env
    {{COMPOSE}} {{RUN_PROFILE}} run --rm resect vnc

#===============================================================================
# Private recipes
#===============================================================================

[default]
[no-exit-message]
_default:
    @just --choose

[private]
build:
    #!/bin/bash
    if [ "$ALLOW_BUILD" = '1' ]; then
        {{COMPOSE}} build resect
    else
        echo "Error: Building is not allowed. Set ALLOW_BUILD to '1' to enable."
    fi