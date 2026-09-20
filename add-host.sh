#!/usr/bin/env bash
# Register a Linux host so the MCP server can reach it over SSH.
#
# Plain SSH:
#   ./add-host.sh <name> <user@host[:port]> [--jump <user@bastion>] [--desc "..."]
# Google Compute Engine:
#   ./add-host.sh <name> --gcloud <instance> --zone <zone> [--project <id>] [--user <u>] [--iap]
#
#   <name>        short alias used as the `host` argument in MCP tool calls
#   --jump        reach the host through a bastion (hosts on another network)
#   --iap         tunnel through IAP (automatic when the VM has no external IP)
#   --skip-copy   don't install the key; it is already authorized
#   --clone-of <host> --run <run-id>
#                 mark this entry as a disposable CLONE of <host>. Tools that run
#                 commands refuse anything without these fields.
set -Eeuo pipefail
cd "$(dirname "$0")"

KEY="${GLOSSY_SSH_KEY:-$HOME/.ssh/id_ed25519_glossy}"
GCE_KEY="${GLOSSY_GCE_KEY:-$HOME/.ssh/google_compute_engine}"
SSH_CONFIG="${GLOSSY_SSH_CONFIG:-$HOME/.ssh/config}"
INVENTORY="${GLOSSY_INVENTORY:-hosts.toml}"

die() { printf 'error: %b\n' "$*" >&2; exit 1; }
log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

name="" target="" jump="" desc="" skip_copy=0 clone_of="" clone_run=""
instance="" zone="" project="" gce_user="" iap=0
while (($#)); do
    case $1 in
        --gcloud) instance="${2:-}"; shift 2 ;;
        --zone) zone="${2:-}"; shift 2 ;;
        --project) project="${2:-}"; shift 2 ;;
        --user) gce_user="${2:-}"; shift 2 ;;
        --iap) iap=1; shift ;;
        --jump) jump="${2:-}"; shift 2 ;;
        --desc) desc="${2:-}"; shift 2 ;;
        --clone-of) clone_of="${2:-}"; shift 2 ;;
        --run) clone_run="${2:-}"; shift 2 ;;
        --skip-copy) skip_copy=1; shift ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        -*) die "unknown option $1" ;;
        *) if [[ -z $name ]]; then name=$1; elif [[ -z $target ]]; then target=$1; else die "too many arguments"; fi; shift ;;
    esac
done
[[ -n $name ]] || die "usage: ./add-host.sh <name> <user@host> | <name> --gcloud <instance> --zone <zone>"
[[ $name =~ ^[A-Za-z0-9_.-]+$ ]] || die "name may only contain letters, digits, dot, dash, underscore"

proxy=""        # ProxyCommand line, used for IAP
identity="$KEY"
host_key_alias=""

if [[ -n $instance ]]; then
    # --- Google Compute Engine -------------------------------------------
    command -v gcloud > /dev/null || die "gcloud is not on PATH"
    [[ -n $zone ]] || die "--gcloud needs --zone (e.g. --zone us-central1-a)"
    [[ -z $target ]] || die "give either <user@host> or --gcloud, not both"
    project="${project:-$(gcloud config get-value project 2>/dev/null)}"
    [[ -n $project && $project != "(unset)" ]] || die "no project; pass --project or run: gcloud config set project <id>"

    log "Looking up $instance in $zone ($project)"
    # Comma-separated: an empty first field means the VM has no external IP.
    IFS=, read -r external_ip instance_id < <(gcloud compute instances describe "$instance" \
        --zone "$zone" --project "$project" \
        --format='value[separator=","](networkInterfaces[0].accessConfigs[0].natIP, id)') \
        || die "instance '$instance' not found in $zone"

    # A VM with no external IP can only be reached through IAP.
    [[ -z $external_ip ]] && iap=1
    identity="$GCE_KEY"
    host_key_alias="compute.$instance_id"

    # gcloud uploads the public key (OS Login or instance metadata) and creates
    # ~/.ssh/google_compute_engine on first use.
    if (( ! skip_copy )); then
        log "Authorizing your key via gcloud"
        tunnel=""; (( iap )) && tunnel="--tunnel-through-iap"
        gcloud compute ssh "$instance" --zone "$zone" --project "$project" \
            ${tunnel} --command true \
            || die "gcloud compute ssh failed; fix that first (IAP needs roles/iap.tunnelResourceAccessor)"
    fi

    user="${gce_user:-$(gcloud compute os-login describe-profile --format='value(posixAccounts[0].username)' 2>/dev/null)}"
    user="${user:-$USER}"
    port=22
    via=""
    if (( iap )); then
        host="$instance"
        proxy="gcloud compute start-iap-tunnel $instance %p --listen-on-stdin --zone=$zone --project=$project"
        via=", via IAP"
    else
        host="$external_ip"
    fi
    desc="${desc:-GCE $instance ($zone)$via}"
else
    # --- plain SSH --------------------------------------------------------
    [[ -n $target ]] || die "usage: ./add-host.sh <name> <user@host[:port]> [--jump user@bastion]"
    [[ $target == *@* ]] || die "target must be user@host"
    [[ -f $KEY ]] || die "no SSH key at $KEY (run ./install.sh)"
    user="${target%%@*}"
    hostport="${target#*@}"
    host="${hostport%%:*}"
    port="22"
    [[ $hostport == *:* ]] && port="${hostport##*:}"
fi

# 1. SSH config entry (this is what makes `host="<name>"` work in MCP tool calls)
mkdir -p "$(dirname "$SSH_CONFIG")"; touch "$SSH_CONFIG"; chmod 600 "$SSH_CONFIG"
if grep -qE "^Host $name([[:space:]]|$)" "$SSH_CONFIG"; then
    log "Host '$name' is already in $SSH_CONFIG; leaving it as is"
else
    log "Adding '$name' to $SSH_CONFIG"
    {
        echo ""
        echo "Host $name  # added by glossy add-host.sh"
        echo "  HostName $host"
        echo "  User $user"
        echo "  Port $port"
        echo "  IdentityFile $identity"
        echo "  IdentitiesOnly yes"
        [[ -n $host_key_alias ]] && echo "  HostKeyAlias $host_key_alias"
        [[ -n $proxy ]] && echo "  ProxyCommand $proxy"
        [[ -n $jump ]] && echo "  ProxyJump $jump"
    } >> "$SSH_CONFIG"
fi

# 2. Learn the host key (so a later change is an error, not a silent accept)
log "Recording host key"
ssh -F "$SSH_CONFIG" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o BatchMode=yes "$name" true 2>/dev/null || true

# 3. Install the public key (plain SSH only; gcloud did this above)
if (( ! skip_copy )) && [[ -z $instance ]]; then
    if ssh -F "$SSH_CONFIG" -o BatchMode=yes -o ConnectTimeout=10 "$name" true 2>/dev/null; then
        log "Key already authorized"
    else
        log "Installing public key (you will be asked for the host's password)"
        ssh-copy-id -i "$KEY.pub" -p "$port" ${jump:+-o "ProxyJump=$jump"} "$user@$host" \
            || die "ssh-copy-id failed"
    fi
fi

# 4. Verify passwordless access, which is what the MCP server needs
log "Verifying"
out=$(ssh -F "$SSH_CONFIG" -o BatchMode=yes -o ConnectTimeout=15 "$name" 'hostname; . /etc/os-release 2>/dev/null && echo "$PRETTY_NAME"' 2>&1) \
    || die "cannot log in to '$name' without a password:\n$out"
echo "$out" | sed 's/^/    /'

# 5. Record it in the inventory
if [[ -f $INVENTORY ]] && grep -q "^name = \"$name\"$" "$INVENTORY"; then
    log "'$name' is already in $INVENTORY"
else
    {
        echo ""
        echo "[[hosts]]"
        echo "name = \"$name\""
        echo "address = \"$user@$host:$port\""
        [[ -n $jump ]] && echo "jump = \"$jump\""
        [[ -n $instance ]] && echo "gce = \"$instance/$zone/$project\""
        # Marks a disposable clone. write/exec tooling keys off these, never off the
        # description text.
        [[ -n $clone_of ]] && echo "clone_of = \"$clone_of\""
        [[ -n $clone_run ]] && echo "run = \"$clone_run\""
        echo "description = \"${desc:-$(echo "$out" | tail -1)}\""
    } >> "$INVENTORY"
    log "Added '$name' to $INVENTORY"
fi

cat <<MSG

'$name' is ready. Use it in MCP tool calls as: host="$name"
Try it:  ssh $name uptime
MSG
