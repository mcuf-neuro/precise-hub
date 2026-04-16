FROM fedora:41

RUN dnf install -y \
      rsync \
      jq \
      zstd \
      tar \
      gzip \
      unzip \
      zip \
      procps-ng \
      vim-minimal \
      less \
    && dnf clean all

COPY scripts/process/config.sh     /opt/precise-hub/process/
COPY scripts/process/logging.sh    /opt/precise-hub/process/
COPY scripts/process/validation.sh /opt/precise-hub/process/
COPY scripts/process/deploy/       /opt/precise-hub/process/deploy/
COPY scripts/process/fetch/        /opt/precise-hub/process/fetch/
COPY scripts/entrypoint.sh /opt/precise-hub/entrypoint.sh

RUN chmod +x /opt/precise-hub/process/*.sh \
             /opt/precise-hub/process/deploy/*.sh \
             /opt/precise-hub/process/fetch/*.sh \
             /opt/precise-hub/entrypoint.sh

WORKDIR /opt/precise-hub

ENTRYPOINT ["/opt/precise-hub/entrypoint.sh"]
