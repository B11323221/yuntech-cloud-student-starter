#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

REGION="us-east-1"
VPC_ID="vpc-0b63fffa51006915e"
SUBNET_ID="subnet-04b255e59eb051929"
AMI_ID="ami-0fef201115eefe936"
SOURCE_CIDR="23.97.62.149/32"
SG_NAME="w03-inspection-sg"
KEY_NAME="w03-inspection-key"
INSTANCE_NAME="w03-inspection-ec2"
USER_DATA_FILE="$ROOT/.local/w03-user-data.sh"
RESOURCES_FILE="$ROOT/.local/resources.json"
GROUP_NAME="${W03_GROUP:-}"
OWNER_CODE="${W03_OWNER:-}"

usage() {
    cat <<'EOF'
Usage: deploy/up.sh --group GROUP --owner OWNER

W03_GROUP and W03_OWNER may be used instead of the options.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --group)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            GROUP_NAME=$2
            shift 2
            ;;
        --owner)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            OWNER_CODE=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
done

[[ -n "$GROUP_NAME" && -n "$OWNER_CODE" ]] || {
    echo "ERROR: provide --group GROUP and --owner OWNER (or W03_GROUP/W03_OWNER)." >&2
    exit 2
}
[[ "$GROUP_NAME" =~ ^[A-Za-z0-9._-]+$ && "$OWNER_CODE" =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo "ERROR: group and owner may contain only letters, numbers, '.', '_' and '-'." >&2
    exit 2
}
[[ ! -e "$RESOURCES_FILE" ]] || {
    echo "ERROR: $RESOURCES_FILE already exists; recover or remove the previous deployment first." >&2
    exit 1
}

mkdir -p "$ROOT/.local"
bash "$ROOT/scripts/verify-aws.sh"

KEY_FILE=""
for candidate in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/w03-inspection-ed25519"; do
    if [[ -f "$candidate" && -f "$candidate.pub" ]] && ssh-keygen -lf "$candidate.pub" 2>/dev/null | grep -q 'ED25519'; then
        KEY_FILE=$candidate
        break
    fi
done
if [[ -z "$KEY_FILE" ]]; then
    KEY_FILE="$HOME/.ssh/w03-inspection-ed25519"
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    ssh-keygen -q -t ed25519 -f "$KEY_FILE" -N '' -C "w03-inspection"
    chmod 600 "$KEY_FILE"
    chmod 644 "$KEY_FILE.pub"
fi
PUBLIC_KEY_FILE="$KEY_FILE.pub"

commit_sha=$(git rev-parse --verify 'HEAD^{commit}')
rm -f "$USER_DATA_FILE"
bash "$ROOT/deploy/make-user-data.sh" HEAD "$USER_DATA_FILE"
chmod 600 "$USER_DATA_FILE"

echo "Resources to create:"
printf '  Security Group: %s in %s\n' "$SG_NAME" "$VPC_ID"
printf '  EC2 key pair:   %s (public key from %s)\n' "$KEY_NAME" "$PUBLIC_KEY_FILE"
printf '  EC2 instance:   %s (%s, %s, %s)\n' "$INSTANCE_NAME" "$AMI_ID" "t3.micro" "$SUBNET_ID"
printf '  Ingress:        TCP 22 and 80 from %s\n' "$SOURCE_CIDR"
printf 'Type CREATE to continue: '
read -r approval
[[ "$approval" == "CREATE" ]] || { echo "Cancelled; no AWS resources were created."; exit 1; }

aws_json() {
    python3 - "$@" <<'PY'
import contextlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path("scripts").resolve()))
import lab

with contextlib.redirect_stdout(sys.stderr):
    context = lab.verify()
print(json.dumps(lab.run_aws(sys.argv[1:], context["region"])))
PY
}

json_field() {
    local document=$1
    local field=$2
    printf '%s' "$document" | python3 -c 'import json, sys; print(json.load(sys.stdin)[sys.argv[1]])' "$field"
}

write_resources() {
    python3 - <<'PY'
import json
import os
import tempfile
from pathlib import Path

path = Path(".local/resources.json")
path.parent.mkdir(mode=0o700, exist_ok=True)
data = {
    "region": os.environ["W03_REGION"],
    "vpc_id": os.environ["W03_VPC_ID"],
    "subnet_id": os.environ["W03_SUBNET_ID"],
    "security_group_id": os.environ.get("W03_SG_ID"),
    "key_pair_id": os.environ.get("W03_KEY_ID"),
    "instance_id": os.environ.get("W03_INSTANCE_ID"),
    "public_ip": os.environ.get("W03_PUBLIC_IP"),
    "group": os.environ["W03_GROUP"],
    "owner": os.environ["W03_OWNER"],
    "commit": os.environ["W03_COMMIT"],
    "tags": {
        "course": "yuntech-115-1",
        "week": "w03",
        "group": os.environ["W03_GROUP"],
        "owner": os.environ["W03_OWNER"],
    },
}
with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as stream:
    json.dump(data, stream, indent=2)
    stream.write("\n")
    temporary = Path(stream.name)
temporary.chmod(0o600)
temporary.replace(path)
PY
}

export W03_REGION="$REGION"
export W03_VPC_ID="$VPC_ID"
export W03_SUBNET_ID="$SUBNET_ID"
export W03_GROUP="$GROUP_NAME"
export W03_OWNER="$OWNER_CODE"
export W03_COMMIT="$commit_sha"

sg_response=$(aws_json ec2 create-security-group --group-name "$SG_NAME" --description "W03 inspection service" --vpc-id "$VPC_ID")
SG_ID=$(json_field "$sg_response" GroupId)
export W03_SG_ID="$SG_ID"
write_resources

aws_json ec2 create-tags --resources "$SG_ID" --tags Key=course,Value=yuntech-115-1 Key=week,Value=w03 Key=group,Value="$GROUP_NAME" Key=owner,Value="$OWNER_CODE" >/dev/null
aws_json ec2 authorize-security-group-ingress --group-id "$SG_ID" --ip-permissions \
    "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$SOURCE_CIDR,Description=Codespace-SSH}]" \
    "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=$SOURCE_CIDR,Description=Codespace-HTTP}]" >/dev/null

key_response=$(aws_json ec2 import-key-pair --key-name "$KEY_NAME" --public-key-material "fileb://$PUBLIC_KEY_FILE")
KEY_ID=$(json_field "$key_response" KeyPairId)
export W03_KEY_ID="$KEY_ID"
write_resources
aws_json ec2 create-tags --resources "$KEY_ID" --tags Key=course,Value=yuntech-115-1 Key=week,Value=w03 Key=group,Value="$GROUP_NAME" Key=owner,Value="$OWNER_CODE" >/dev/null

instance_response=$(aws_json ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type t3.micro \
    --count 1 \
    --subnet-id "$SUBNET_ID" \
    --security-group-ids "$SG_ID" \
    --key-name "$KEY_NAME" \
    --associate-public-ip-address \
    --metadata-options HttpEndpoint=enabled,HttpTokens=required \
    --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=8,VolumeType=gp3,Encrypted=true,DeleteOnTermination=true}" \
    --user-data "file://$USER_DATA_FILE" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=course,Value=yuntech-115-1},{Key=week,Value=w03},{Key=group,Value=$GROUP_NAME},{Key=owner,Value=$OWNER_CODE}]" "ResourceType=volume,Tags=[{Key=Name,Value=$INSTANCE_NAME-root},{Key=course,Value=yuntech-115-1},{Key=week,Value=w03},{Key=group,Value=$GROUP_NAME},{Key=owner,Value=$OWNER_CODE}]")
INSTANCE_ID=$(printf '%s' "$instance_response" | python3 -c 'import json, sys; print(json.load(sys.stdin)["Instances"][0]["InstanceId"])')
export W03_INSTANCE_ID="$INSTANCE_ID"
write_resources

echo "Waiting for instance $INSTANCE_ID to enter running state..."
aws_json ec2 wait instance-running --instance-ids "$INSTANCE_ID" >/dev/null

public_ip=""
for attempt in $(seq 1 60); do
    : "$attempt"
    instance_state=$(aws_json ec2 describe-instances --instance-ids "$INSTANCE_ID")
    public_ip=$(printf '%s' "$instance_state" | python3 -c 'import json, sys; print(json.load(sys.stdin)["Reservations"][0]["Instances"][0].get("PublicIpAddress", ""))')
    if [[ -n "$public_ip" ]]; then
        break
    fi
    sleep 5
done
[[ -n "$public_ip" ]] || { echo "ERROR: instance has no public IPv4 address." >&2; exit 1; }
export W03_PUBLIC_IP="$public_ip"
write_resources

echo "Instance public IPv4: $public_ip"
echo "Polling /health for commit $commit_sha..."
for attempt in $(seq 1 60); do
    : "$attempt"
    health_output=$(curl --silent --show-error --max-time 8 --write-out $'\n%{http_code}' "http://$public_ip/health" 2>/dev/null || true)
    health_code=${health_output##*$'\n'}
    health_body=${health_output%$'\n'*}
    if [[ "$health_code" == "200" ]] && python3 - "$commit_sha" "$health_body" <<'PY'
import json
import sys

try:
    payload = json.loads(sys.argv[2])
except (IndexError, json.JSONDecodeError):
    raise SystemExit(1)
raise SystemExit(0 if payload.get("status") == "ok" and payload.get("service") == "inspection" and payload.get("version") == sys.argv[1] else 1)
PY
    then
        echo "Health check passed: HTTP 200, version $commit_sha"
        exit 0
    fi
    sleep 10
done

echo "ERROR: /health did not return HTTP 200 with the expected commit within the timeout." >&2
echo "The instance remains recorded in $RESOURCES_FILE for inspection or deploy/down.sh cleanup." >&2
exit 1
