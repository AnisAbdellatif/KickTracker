#!/bin/sh
# Writes definitions.prod.json: the development topology (vhost "/" only)
# with production users and passwords from the environment. Run on the
# server after decrypting the secrets; the output is git-ignored.
#
#   set -a; . secrets/rabbitmq.env; set +a; ./rabbitmq/make-prod-definitions.sh
#
# Needs RABBITMQ_ADMIN_PASSWORD, RABBITMQ_RECEIVER_PASSWORD,
# RABBITMQ_APP_PASSWORD, RABBITMQ_OPS_PASSWORD, RABBITMQ_MONITOR_PASSWORD.
set -eu
cd "$(dirname "$0")"
python3 - <<'PY'
import base64, hashlib, json, os

def rabbit_hash(password):
    # rabbit_password_hashing_sha256: base64(salt ++ sha256(salt ++ password))
    salt = os.urandom(4)
    return base64.b64encode(salt + hashlib.sha256(salt + password.encode()).digest()).decode()

d = json.load(open("definitions.dev.json"))
passwords = {u: os.environ[f"RABBITMQ_{u.upper()}_PASSWORD"] for u in ["admin", "receiver", "app", "ops", "monitor"]}
for p in passwords.values():
    assert len(p) >= 24, "use passwords of 24 characters or more"

d["vhosts"] = [v for v in d["vhosts"] if v["name"] == "/"]
d["permissions"] = [p for p in d["permissions"] if p["vhost"] == "/"]
for key in ("queues", "exchanges", "bindings", "policies"):
    d[key] = [x for x in d.get(key, []) if x.get("vhost") == "/"]
for u in d["users"]:
    u["password_hash"] = rabbit_hash(passwords[u["name"]])

with open("definitions.prod.json", "w") as f:
    json.dump(d, f, indent=2)
# Readable by the broker, which runs as its own user in its container (a
# 0640 file of ours is unreadable to it, and RabbitMQ refuses to boot).
# It holds salted hashes, not passwords.
os.chmod("definitions.prod.json", 0o644)
print("wrote definitions.prod.json")
PY
