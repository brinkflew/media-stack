#!/usr/bin/env python3
# =============================================================================
# Substitute .env values into a tracked config template
# -----------------------------------------------------------------------------
# RUNS ON THE SERVER, from an ExecStartPre= on the unit that consumes the
# output. It exists because two of the containers here read a config file and
# substitute NOTHING in it - the same trap apps/prometheus/prometheus.yml
# already documents, and one that costs more when the value is a credential
# rather than a port.
#
#   ntfy               server.yml holds bcrypt password hashes
#   ntfy-alertmanager  scfg holds the ntfy password and the webhook password
#
# WHY NOT Environment= IN THE QUADLET, which is how every other secret here
# reaches a container. Because a bcrypt hash is full of `$`, and it would pass
# through two layers that each claim that character: systemd expands `${...}`
# and reads `$$` as a literal `$`, and ntfy's own env parser then does its own
# `$$` unescaping. Getting a hash through both intact means double-escaping it
# in sops, where it is no longer reviewable and no longer matches what
# `ntfy user hash` printed. A file has neither problem - YAML and scfg treat
# `$` as an ordinary character - so the value in sops is the value on disk.
#
# IT REFUSES ON AN UNSET VARIABLE rather than substituting an empty string.
# That is the `${VAR:?err}` convention from .env.sample, and it matters more
# here than it does in Compose: an empty password in a rendered config is not a
# startup failure, it is a service that comes up and authenticates nobody.
# systemd's own `${VAR}` expansion does exactly the wrong thing here, which is
# why quadlets that interpolate need EnvironmentFile= and this needs to be
# stricter than they are.
#
# THE OUTPUT IS 0600 AND WRITTEN THROUGH A TEMPORARY FILE. A half-written
# config read by a container that starts a second later is a failure mode with
# no error message anywhere; the rename is atomic, so a reader sees the old
# file or the new one.
#
# Usage:  bin/render-template.py <template> <output>
#         bin/render-template.py --check <template>     names the variables
# =============================================================================

import os
import re
import sys

# Derived from this file's own location rather than hardcoded, for the reason
# render-jellyfin-branding.py gives: a stale literal here fails every start.
REPO = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
ENV = os.path.join(REPO, ".env")

# ${NAME} only. A bare $NAME is NOT a reference here, deliberately: bcrypt
# hashes are `$2a$10$...` and a shell-style parser would try to expand `$2a`,
# find nothing, and quietly blank the credential.
REF = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")


def load_env(path=ENV):
    """Parse .env the way collect-metrics.py does, and for the same reason.

    Not `source`: this must not execute anything, and the file is rendered
    from sops by bin/render-env.sh with values that may contain almost
    anything. Quotes are stripped because render-env.sh does not add them and
    a hand-edited file might.
    """
    env = {}
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                env[key.strip()] = value.strip().strip('"').strip("'")
    except OSError as exc:
        sys.exit("render-template: cannot read %s: %s" % (path, exc))
    return env


def main():
    args = [a for a in sys.argv[1:] if a != "--check"]
    check = "--check" in sys.argv
    if len(args) != (1 if check else 2):
        sys.exit(__doc__ or "usage: render-template.py <template> <output>")

    template = args[0]
    try:
        with open(template, encoding="utf-8") as handle:
            body = handle.read()
    except OSError as exc:
        sys.exit("render-template: cannot read %s: %s" % (template, exc))

    names = sorted(set(REF.findall(body)))
    if check:
        print("\n".join(names))
        return

    env = load_env()
    # Collected and reported TOGETHER. Failing on the first missing variable
    # means a three-secret template takes three deploys to get right, each one
    # a container restart away from the message.
    missing = [n for n in names if not env.get(n)]
    if missing:
        sys.exit("render-template: unset in .env: %s" % ", ".join(missing))

    rendered = REF.sub(lambda match: env[match.group(1)], body)

    output = args[1]
    try:
        os.makedirs(os.path.dirname(output) or ".", exist_ok=True)
        tmp = output + ".tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            handle.write(rendered)
        os.chmod(tmp, 0o600)
        os.replace(tmp, output)
    except OSError as exc:
        sys.exit("render-template: cannot write %s: %s" % (output, exc))


if __name__ == "__main__":
    main()
