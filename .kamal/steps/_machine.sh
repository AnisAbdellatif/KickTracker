# shellcheck shell=bash
# shellcheck disable=SC2034 # set for the step that sources this
# Sourced by the project's steps: which machine this deploy acts on, from
# the Kamal config it runs with. The shadow machine's configs
# (deploy/kamal/shadow.yml, backup-receiver.yml; deploy/shadow.sh) have
# their own checkout folder and secrets; everything else is the main VPS.
case ${KIT_KAMAL_CONFIG_FILE:-} in
  *shadow.yml | *backup-receiver.yml)
    kt_machine=shadow
    kt_dir=${KT_SHADOW_DEPLOY_DIR:-/srv/kick_tracker}
    kt_secrets=$kt_dir/deploy/secrets
    ;;
  *)
    kt_machine=main
    kt_dir=${KT_DEPLOY_DIR:-/srv/kick_tracker}
    kt_secrets=${KT_SECRETS_DIR:-$kt_dir/deploy/secrets}
    ;;
esac
