# shellcheck shell=bash disable=SC2034
# deploy-kit's defaults. Every setting here can be overridden in
# .kamal/kit.env, per destination, locally or from the environment
# (lib/core.sh, "configuration"). docs/configuration.md describes each one.

# --- Kamal
KIT_KAMAL=kamal                 # the command: kamal, bin/kamal, "bundle exec kamal"
KIT_KAMAL_CONFIG_FILE=          # -c; empty: Kamal's default (config/deploy.yml)
KIT_ROLES=                      # all roles; empty: read from `kamal config`

# --- Where Kamal runs (docs/runner.md). Read without a destination.
KIT_RUNNER=local                # local: this machine's Kamal; docker: the kit's image (Kamal, bash, gh, sops)
KIT_RUNNER_IMAGE=               # empty: deploy-kit:<version>, built from sandbox/Dockerfile
KIT_RUNNER_ENV=                 # more variables to pass in (NAMES; KIT_* and KAMAL_* always are)
KIT_RUNNER_NETWORK=             # docker run --network; empty: Docker's default
KIT_RUNNER_SSH_DIR=             # empty: ~/.ssh
KIT_RUNNER_SSH_WRITABLE=false   # ~/.ssh read-only in the container (but known_hosts); true: read-write
KIT_RUNNER_SSH_AGENT=auto       # auto: $SSH_AUTH_SOCK (Docker Desktop's on a Mac); none; or a socket path
KIT_RUNNER_DOCKER_SOCKET=auto   # auto: /var/run/docker.sock, none with KIT_DEPLOY_SKIP_PUSH; a path; none

# --- Hooks: which steps each Kamal hook runs, in order. Names are the
# kit's steps (steps/), the project's (.kamal/steps/), or paths. The
# project's .kamal/hooks.d/<hook>/* scripts run after these. The gates run
# in pre-deploy (which every deploy, redeploy and rollback runs, also with
# --skip-push); the fast git ones also in pre-build, so a wrong branch
# isn't built for nothing. pre-connect runs for every command that reaches
# a server (even `kamal app logs`), so it only holds the role guard.
KIT_HOOK_PRE_CONNECT="role-guard"
KIT_HOOK_PRE_BUILD="freeze require-branch require-clean require-pushed"
KIT_HOOK_PRE_DEPLOY="freeze role-guard require-branch require-pushed ci-green notify"
KIT_HOOK_POST_DEPLOY="smoke notify"
KIT_HOOK_PRE_APP_BOOT="role-guard"  # `kamal app boot` of a group role
KIT_HOOK_POST_APP_BOOT=
KIT_HOOK_PRE_PROXY_REBOOT=
KIT_HOOK_POST_PROXY_REBOOT=
KIT_HOOK_DOCKER_SETUP=

KIT_SKIP=                        # steps to skip this once: KIT_SKIP=ci-green kit deploy
KIT_SKIP_REASON=                 # why (in the warning and the notification)
KIT_SKIP_REASON_REQUIRED=false   # refuse a skip without a reason (e.g. KIT_SKIP_REASON_REQUIRED_PRODUCTION=true)
KIT_STEP_TIMEOUT=600             # seconds per step (KIT_STEP_TIMEOUT_<STEP> for one); 0: none
KIT_UNSKIPPABLE=                 # steps KIT_SKIP can't skip; read from the committed kit.env only
KIT_CACHED_STEPS="require-branch require-clean require-pushed ci-green attestation confirm freeze"

# --- Git gates
KIT_DEPLOY_BRANCH=main           # branches allowed to deploy (a list)
KIT_GIT_REMOTE=origin
KIT_PUSHED_MODE=contained        # contained: HEAD is on the remote branch; tip: HEAD is its tip
KIT_CLEAN_IGNORE_UNTRACKED=true

# --- CI gate (GitHub, via gh)
KIT_GITHUB_REPO=                 # owner/repo; empty: from gh
KIT_CI_REQUIRED=                 # check names that must pass; empty: every check must pass
KIT_CI_IGNORE=                   # check names never looked at
KIT_CI_WAIT=0                    # seconds to wait for running checks; 0: fail at once
KIT_CI_POLL=15
KIT_CI_ALLOW_NONE=false          # pass when the commit has no checks at all
KIT_CI_APP=                      # only check runs of these GitHub Apps (e.g. github-actions); then statuses aren't read

# --- Attestation gate (images built by CI, see docs/security.md)
KIT_IMAGE=                       # empty: Kamal's (kamal config's repository), which it must be anyway
KIT_ATTESTATION_SIGNER_WORKFLOW= # e.g. owner/app/.github/workflows/build.yml
KIT_ATTESTATION_SOURCE_DIGEST=true  # the image was built from the commit deployed (a full commit id)
KIT_ATTESTATION_SOURCE_REF=      # built from this ref; empty: the checkout's branch; none: any
KIT_ATTESTATION_DENY_SELF_HOSTED=true  # built on GitHub's runners, not self-hosted ones
KIT_ATTESTATION_ARGS=            # extra `gh attestation verify` arguments
KIT_ATTESTATION_WITHOUT_DOCKER=refuse  # no docker to resolve the digest: refuse; tag: verify the tag, warned

# --- Confirmation
KIT_CONFIRM=false                # e.g. KIT_CONFIRM_PRODUCTION=true
KIT_CONFIRM_NONINTERACTIVE=fail  # fail | allow, when there is no terminal

# --- Freeze
KIT_FREEZE=false                 # or create .kamal/FREEZE (or FREEZE.<destination>)
KIT_FREEZE_ALLOWS_ROLLBACK=true

# --- Smoke tests
KIT_SMOKE_URLS=                  # URL[|STATUS[|TEXT]] ...; STATUS like 200 or 2xx
KIT_SMOKE_RETRIES=10
KIT_SMOKE_INTERVAL=3
KIT_SMOKE_TIMEOUT=10
KIT_SMOKE_CURL_ARGS=

# --- kit deploy
KIT_AUTO_ROLLBACK=true           # roll back when smoke tests fail after a deploy
KIT_LOCK=true                    # hold Kamal's deploy lock for the whole kit deploy / group deploy / switch
KIT_DEPLOY_SKIP_PUSH=false       # always -P: images are built elsewhere (by CI)
KIT_CHECK_IMAGE=true             # with -P: check the registry has the image before deploying (docker manifest inspect)
KIT_GROUP_ORDER=                 # groups deployed in this order; empty: alphabetical
KIT_PRIMARY_ROLE=                # the role whose version is "the" version; empty: first plain role

# --- Groups (defaults for .kamal/groups/<name>/group.env)
KIT_GROUP_STOP_FIRST=true
KIT_GROUP_GUARD=true
KIT_GROUP_HEALTH_TIMEOUT=180
KIT_GROUP_SWITCH_TIMEOUT=90
KIT_GROUP_INTERVAL=2
KIT_GROUP_ON_SWITCH_FAILURE=report  # report | switch-back
KIT_GROUP_RESTORE_ON_FAILURE=false
KIT_GROUP_ROLLING_ORDER=listed      # listed | inactive-first
KIT_KAMAL_EXEC_RAW=true             # `kamal app exec --raw` (Kamal 2.12 has it); false: older Kamal, host headers stripped

# --- Notifications
KIT_NOTIFY=                      # channels; empty: every configured one
KIT_NOTIFY_LEVELS="success warning error"
KIT_NOTIFY_PREFIX=
KIT_TELEGRAM_BOT_TOKEN=
KIT_TELEGRAM_CHAT_ID=
KIT_WEBHOOK_URL=                 # Slack, Discord, Mattermost, or anything taking {"text": …}
KIT_NTFY_URL=
KIT_NTFY_TOKEN=
KIT_NOTIFY_COMMAND=
KIT_NOTIFY_TIMEOUT=30            # seconds for the command and .kamal/notifiers/* scripts
KIT_PING_URL=                    # `kit ping`'s URL (a heartbeat, e.g. healthchecks.io), kept off command lines

# --- kit sandbox (docs/sandbox.md; usually set in .kamal/sandbox/sandbox.env)
KIT_SANDBOX_CONFIGS=             # Kamal configs, in order; empty: the project's
KIT_SANDBOX_NAME=                # container names' part; empty: the folder's name and a hash of its path
KIT_SANDBOX_SSH_PORT=2222
KIT_SANDBOX_REGISTRY_PORT=5555
KIT_SANDBOX_PROXY_PORT=8080      # kamal-proxy's HTTP port, for roles behind it
KIT_SANDBOX_PROXY_TLS_PORT=8443
KIT_SANDBOX_SERVER_PATH=/srv/sandbox  # where hooks' server files appear on the "server"
KIT_SANDBOX_ENV=                 # NAME=value ... for the deployer (what your Kamal configs' ERB reads)
KIT_SANDBOX_NOTIFY=false         # send the kit's notifications from the sandbox too
KIT_SANDBOX_IMAGE=               # empty: KIT_RUNNER_IMAGE (the kit's image, deploy-kit:<version>)
