# shellcheck shell=bash disable=SC2034
# deploy-kit's defaults. Every setting here can be overridden in
# .kamal/kit.env, per destination, locally or from the environment
# (lib/core.sh, "configuration"). docs/configuration.md describes each one.

# --- Kamal
KIT_KAMAL=kamal                 # the command: kamal, bin/kamal, "bundle exec kamal"
KIT_KAMAL_CONFIG_FILE=          # -c; empty: Kamal's default (config/deploy.yml)
KIT_ROLES=                      # all roles; empty: read from `kamal config`

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
KIT_HOOK_PRE_APP_BOOT=
KIT_HOOK_POST_APP_BOOT=
KIT_HOOK_PRE_PROXY_REBOOT=
KIT_HOOK_POST_PROXY_REBOOT=
KIT_HOOK_DOCKER_SETUP=

KIT_SKIP=                        # steps to skip this once: KIT_SKIP=ci-green kit deploy
KIT_STEP_TIMEOUT=600             # seconds per step; 0: none
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

# --- Attestation gate (images built by CI, see docs/security.md)
KIT_IMAGE=                       # e.g. ghcr.io/owner/app
KIT_ATTESTATION_SIGNER_WORKFLOW= # e.g. owner/app/.github/workflows/build.yml
KIT_ATTESTATION_ARGS=            # extra `gh attestation verify` arguments

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
KIT_DEPLOY_SKIP_PUSH=false       # always -P: images are built elsewhere (by CI)
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
