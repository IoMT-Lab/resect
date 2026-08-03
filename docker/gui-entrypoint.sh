#!/bin/bash
set -e

# Default to 1000 if variables are not passed
USER_ID=${HOST_UID:-1000}
GROUP_ID=${HOST_GID:-1000}

# Define a name for the group and user inside the container
CONTAINER_USER="appuser"
CONTAINER_GROUP="appgroup"

# 1. Dynamically create the group if the GID doesn't exist yet
if ! getent group "$GROUP_ID" >/dev/null; then
    groupadd -g "$GROUP_ID" "$CONTAINER_GROUP"
else
    CONTAINER_GROUP=$(getent group "$GROUP_ID" | cut -d: -f1)
fi

# 2. Dynamically create the user if the UID doesn't exist yet
if ! getent passwd "$USER_ID" >/dev/null; then
    useradd -s /bin/bash -u "$USER_ID" -g "$GROUP_ID" -m "$CONTAINER_USER"
else
    CONTAINER_USER=$(getent passwd "$USER_ID" | cut -d: -f1)
fi

# 3. Ensure your app directory or home path is owned by the resolved user
export HOME=$(getent passwd "$USER_ID" | cut -d: -f6)

# Create a symlink at $HOME/.config pointing to /static_home
mkdir -p /static_home
ln -snf /static_home "$HOME/.config"
chown -R "$USER_ID":"$GROUP_ID" "$HOME"
chown -R "$USER_ID":"$GROUP_ID" /static_home

echo "Creating virtual display and starting VNC server..."
rm -f /tmp/.X99-lock
Xvfb :99 -screen 0 1600x1000x24 -ac >/tmp/xvfb.log 2>&1 &
sleep 1
x11vnc -display :99 -forever -nopw -shared -rfbport 5900 >/tmp/x11vnc.log 2>&1 &
sleep 1
export DISPLAY=:99

# 4. Hand off execution to your app as the non-root user
echo "Starting container as user: $CONTAINER_USER (UID: $USER_ID, GID: $GROUP_ID)"

echo "Resect GUI available as 'resect' and VNC server available on port 5900"
exec gosu "$CONTAINER_USER" "$@"