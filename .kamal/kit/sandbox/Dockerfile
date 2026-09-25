# deploy-kit's sandbox image (docs/sandbox.md). One image, two parts:
# - the deployer: Kamal and bash, to run the kit as the machine that
#   deploys would;
# - the server: sshd and a Docker CLI on this machine's Docker, where the
#   deployer's Kamal deploys to.
ARG KAMAL_VERSION=v2.12.0
FROM ghcr.io/basecamp/kamal:${KAMAL_VERSION}
RUN apk add --no-cache bash curl openssh-server openssh-sftp-server \
 && ssh-keygen -A \
 && mkdir -p /root/.ssh && chmod 700 /root/.ssh
# Kamal's image runs `kamal` by default; here the command is given.
ENTRYPOINT []
CMD ["bash"]
