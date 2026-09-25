# The rehearsal's two stand-ins (../README.md), one image:
# - the machine that deploys: Kamal (this image's own) and the kit, run as
#   `kit … -d rehearsal` from the checkout;
# - the server Kamal deploys to: sshd and a Docker CLI on this machine's
#   Docker, with the rehearsal's deploy/ where the server's checkout is.
FROM ghcr.io/basecamp/kamal:latest
RUN apk add --no-cache bash curl openssh-server openssh-sftp-server \
 && ssh-keygen -A \
 && mkdir -p /root/.ssh && chmod 700 /root/.ssh
# Kamal's image runs `kamal` by default; here the command is given.
ENTRYPOINT []
CMD ["bash"]
