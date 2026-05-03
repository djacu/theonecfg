# bootstrap-homelab-secrets <hostname>
#
# Generates fresh secret values for secrets/<hostname>.yaml and encrypts
# them via sops using the matching creation_rule in .sops.yaml.
#
# The generated structure is the homelab service stack (kanidm, *arr,
# jellyfin, qbittorrent, postgres per app, etc.). To support a different
# host with a different mix of services, add a new template_<hostname>()
# function and a matching case in the dispatcher below.
#
# Usage:
#   nix run .#theonecfg.bootstrap-homelab-secrets -- <hostname>
#
# Currently supported hosts: scheelite.

if [ $# -lt 1 ]; then
    echo "Usage: $0 <hostname>" >&2
    echo "Supported hosts: scheelite" >&2
    exit 1
fi

target_host="$1"
output_path="./secrets/${target_host}.yaml"

if [ -e "$output_path" ]; then
    echo "Error: $output_path already exists." >&2
    echo "Refusing to overwrite. To regenerate, delete it first:" >&2
    echo "    rm $output_path" >&2
    exit 1
fi

# sops walks from PWD upward looking for .sops.yaml at each level (per
# sops source: config/config.go LookupConfigFile). It does NOT look in
# subdirectories, so .sops.yaml living at secrets/.sops.yaml is invisible
# to that walk. We do our own walk that checks both ./<level>/.sops.yaml
# and ./<level>/secrets/.sops.yaml, then pass --config explicitly to sops.
find_sops_config() {
    local dir
    dir="$(pwd)"
    while [ -n "$dir" ] && [ "$dir" != "/" ]; do
        if [ -f "$dir/.sops.yaml" ]; then
            echo "$dir/.sops.yaml"
            return 0
        fi
        if [ -f "$dir/secrets/.sops.yaml" ]; then
            echo "$dir/secrets/.sops.yaml"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

sops_config="$(find_sops_config)" || {
    echo "Error: could not find .sops.yaml in PWD or any parent." >&2
    echo "Run this from within the project repository." >&2
    exit 1
}

# Generators (CSPRNG-backed via openssl/uuidgen)
gen_password() { openssl rand -hex 24; }              # 48 hex chars
gen_oauth_secret() { openssl rand -hex 32; }          # 64 hex chars
gen_cookie_secret() { openssl rand -base64 32 | tr -d '\n'; }  # 44 char base64
gen_uuid() { uuidgen; }                               # RFC 4122 v4

# Plaintext stays in /tmp (mktemp -> mode 600). Trap removes it on any
# exit path including failure.
tmpfile="$(mktemp -t bootstrap-homelab-secrets.XXXXXX.yaml)"
trap 'rm -f "$tmpfile"' EXIT

template_scheelite() {
    cat > "$tmpfile" <<EOF
kanidm:
  admin: $(gen_password)
  idm-admin: $(gen_password)
  oauth-grafana: $(gen_oauth_secret)
  oauth-jellyfin: $(gen_oauth_secret)
  oauth-nextcloud: $(gen_oauth_secret)
  oauth-immich: $(gen_oauth_secret)
  oauth-paperless: $(gen_oauth_secret)
  oauth-proxy: $(gen_oauth_secret)
oauth2-proxy:
  cookie-secret: $(gen_cookie_secret)
sonarr:
  api-key: $(gen_uuid)
  postgres-password: $(gen_password)
sonarr-anime:
  api-key: $(gen_uuid)
  postgres-password: $(gen_password)
radarr:
  api-key: $(gen_uuid)
  postgres-password: $(gen_password)
whisparr:
  api-key: $(gen_uuid)
  postgres-password: $(gen_password)
prowlarr:
  api-key: $(gen_uuid)
  postgres-password: $(gen_password)
qbittorrent:
  password: $(gen_password)
jellyfin:
  admin-password: $(gen_password)
nextcloud:
  admin-password: $(gen_password)
  db-password: $(gen_password)
immich:
  db-password: $(gen_password)
paperless:
  admin-password: $(gen_password)
  db-password: $(gen_password)
EOF
}

case "$target_host" in
    scheelite)
        template_scheelite
        ;;
    *)
        echo "Error: no template defined for host '$target_host'." >&2
        echo "" >&2
        echo "Add a template_${target_host}() function and a matching case" >&2
        echo "in bootstrap.sh." >&2
        exit 1
        ;;
esac

mkdir -p "$(dirname "$output_path")"

# sops uses:
#   --config: explicit path to .sops.yaml (skips its PWD walk).
#   --filename-override: tells sops to match creation_rules against
#     <output_path> rather than the input file's tmp path. Without this,
#     the regex is matched against /tmp/... and never matches.
# PGP encryption touches the YubiKey.
sops --config "$sops_config" \
     --filename-override "$output_path" \
     --encrypt \
     --input-type yaml \
     --output-type yaml \
     --output "$output_path" \
     "$tmpfile"

echo
echo "Encrypted secrets written to: $output_path"
echo
echo "Verify by viewing the structure (touches YubiKey):"
echo "    sops $output_path"
echo
echo "After ${target_host} reinstall:"
echo "  1. Derive its age public key:"
echo "       ssh ${target_host} 'cat /etc/ssh/ssh_host_ed25519_key.pub' \\"
echo "         | nix shell --inputs-from . nixpkgs#ssh-to-age -c ssh-to-age"
echo "  2. Replace TODO_REPLACE... in .sops.yaml's &${target_host}_host"
echo "     anchor and uncomment the corresponding age recipient in the"
echo "     matching creation_rule."
echo "  3. Re-encrypt for the new recipient list:"
echo "       sops updatekeys $output_path"
