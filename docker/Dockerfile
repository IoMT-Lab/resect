FROM nexus.medmakers.io/docker/flutter:3.44.6 AS builder

WORKDIR /src
COPY emulator_orchestrator emulator_orchestrator
COPY emulator_ui emulator_ui
COPY pubspec.yaml pubspec.yaml
COPY pubspec.lock pubspec.lock

RUN flutter pub get && \
    cd emulator_orchestrator && \
    dart run build_runner build --delete-conflicting-outputs && \
    cd .. && \
    dart build cli --target emulator_orchestrator/bin/cli.dart && \
    cd emulator_ui && \
    flutter build linux



FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    # Install base dependencies
    binutils-arm-none-eabi \
    libsqlite3-dev \
    gosu \
    # Install GUI dependencies
    libgtk-3-dev \
    liblzma-dev \
    libwayland-client0 \
    libwayland-egl1 \
    libx11-xcb1 \
    adwaita-icon-theme \
    # Install VNC dependencies
    xvfb \
    x11vnc \
    zenity \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/build/cli/linux_x64/bundle/bin/cli /bin/resect-cli
COPY --from=builder /src/emulator_ui/build/linux/x64/release/bundle /bin/resect
ENV PATH="/bin:/bin/resect:${PATH}"

COPY docker/resect.config /resect.config
ENV RESECT_CONFIG=/resect.config

COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 5900
ENTRYPOINT ["/entrypoint.sh"]
CMD ["cli"]