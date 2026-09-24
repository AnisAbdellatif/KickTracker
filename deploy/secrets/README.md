# Secrets

Encrypted with [sops](https://github.com/getsops/sops) and
[age](https://github.com/FiloSottile/age) (project.md §19.3). Only the
`*.sops.env` files are committed; the decrypted `*.env` files are
git-ignored and live only on the server.

| File | Used by | Holds |
|---|---|---|
| `stack.env` | Caddy | `SITE_HOST`, `INGRESS_HOST`, `ACME_EMAIL`, `ADMIN_ALLOW` |
| `app.env` | collector, web, migrate | see `app.env.example` |
| `receiver.env` | both receivers | see `receiver.env.example` |
| `db.env` | the database and the backups | see `db.env.example` |
| `rabbitmq.env` | `rabbitmq/make-prod-definitions.sh` | the five RabbitMQ passwords |

## First time

1. Make an age key on the server and on each admin's machine:
   `age-keygen -o ~/.config/sops/age/keys.txt`, and put the public keys in
   `../../.sops.yaml` (replacing the placeholder).
2. Copy each `*.example` to its name without `.example`, fill it in, and
   encrypt it: `sops --encrypt app.env > app.sops.env`.
3. Commit only the `*.sops.env` files.

## On the server

    cd deploy/secrets
    for f in *.sops.env; do sops --decrypt "$f" > "${f%.sops.env}.env"; done
    chmod 600 *.env

Rotate a secret by editing it in place (`sops app.sops.env`), committing,
decrypting on the server and redeploying the services that use it.
