# deploy-kit's image: Kamal, and what the kit needs beside it. Built on
# first use as deploy-kit:<version> (the folder keeps its first name,
# sandbox/, so older kits can still `kit update` to this one). Used as:
# - the kit's runner (KIT_RUNNER=docker, docs/runner.md): Kamal and the
#   kit run here instead of on this machine; bash for the kit and its
#   hooks, curl for smoke tests and notifications, gh for the CI and
#   attestation gates, sops and age for secrets;
# - the sandbox's deployer (the same, playing the machine that deploys) and
#   its server: sshd and a Docker CLI on this machine's Docker, where the
#   deployer's Kamal deploys to (docs/sandbox.md).
ARG KAMAL_VERSION=v2.12.0
FROM ghcr.io/basecamp/kamal:${KAMAL_VERSION}
RUN apk add --no-cache bash curl github-cli sops age openssh-server openssh-sftp-server \
 && ssh-keygen -A \
 && mkdir -p /root/.ssh && chmod 700 /root/.ssh \
 && mkdir -p /home/kit && chmod 1777 /home/kit
# The container runs as the user running the kit, who has no account here:
# a home anyone can write to (~/.ssh is mounted into it).
ENV HOME=/home/kit
# Kamal's image runs `kamal` by default; here the command is given.
ENTRYPOINT []
CMD ["bash"]
