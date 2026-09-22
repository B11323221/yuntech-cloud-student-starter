#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
RESOURCES_FILE="$ROOT/.local/resources.json"

usage() {
    cat <<'EOF'
Usage: deploy/down.sh [--stop]

Without --stop, terminate the recorded instance and delete its dedicated
security group and imported key pair. With --stop, only stop the instance.
EOF
}

stop_only=false
case "${1:-}" in
    "") ;;
    --stop) stop_only=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

[[ -f "$RESOURCES_FILE" ]] || {
    echo "ERROR: $RESOURCES_FILE does not exist." >&2
    exit 1
}

bash "$ROOT/scripts/verify-aws.sh"

read_resource() {
    local field=$1
    python3 - "$RESOURCES_FILE" "$field" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
value = data.get(sys.argv[2])
if not value:
    raise SystemExit(f"missing resource field: {sys.argv[2]}")
print(value)
PY
}

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

expect_absent() {
    python3 - "$@" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, str(Path("scripts").resolve()))
import lab

context = lab.verify()
try:
    lab.run_aws(sys.argv[1:], context["region"])
except lab.LabError as exc:
    message = str(exc)
    if "NotFound" in message or "InvalidGroup" in message or "InvalidKeyPair" in message:
        print(f"Confirmed absent: {' '.join(sys.argv[1:])}")
        raise SystemExit(0)
    raise
raise SystemExit(f"resource still exists: {' '.join(sys.argv[1:])}")
PY
}

instance_id=$(read_resource instance_id)
security_group_id=$(read_resource security_group_id)
key_pair_id=$(read_resource key_pair_id)
vpc_id=$(read_resource vpc_id)
subnet_id=$(read_resource subnet_id)
group_name=$(read_resource group)
owner_code=$(read_resource owner)

verify_tags() {
    local resource_type=$1
    local resource_id=$2
    local response
    case "$resource_type" in
        instance)
            response=$(aws_json ec2 describe-instances --instance-ids "$resource_id")
            RESPONSE="$response" EXPECTED_GROUP="$group_name" EXPECTED_OWNER="$owner_code" python3 - <<'PY'
import json
import os
instances = json.loads(os.environ["RESPONSE"])["Reservations"][0]["Instances"]
tags = {item["Key"]: item["Value"] for item in instances[0].get("Tags", [])}
expected = {"course": "yuntech-115-1", "week": "w03", "group": os.environ["EXPECTED_GROUP"], "owner": os.environ["EXPECTED_OWNER"]}
if any(tags.get(key) != value for key, value in expected.items()):
    raise SystemExit("instance ownership tags do not match resources.json")
PY
            ;;
        security-group)
            response=$(aws_json ec2 describe-security-groups --group-ids "$resource_id")
            RESPONSE="$response" EXPECTED_GROUP="$group_name" EXPECTED_OWNER="$owner_code" python3 - <<'PY'
import json
import os
groups = json.loads(os.environ["RESPONSE"])["SecurityGroups"]
tags = {item["Key"]: item["Value"] for item in groups[0].get("Tags", [])}
expected = {"course": "yuntech-115-1", "week": "w03", "group": os.environ["EXPECTED_GROUP"], "owner": os.environ["EXPECTED_OWNER"]}
if any(tags.get(key) != value for key, value in expected.items()):
    raise SystemExit("security group ownership tags do not match resources.json")
PY
            ;;
        key-pair)
            response=$(aws_json ec2 describe-key-pairs --key-pair-ids "$resource_id")
            RESPONSE="$response" EXPECTED_GROUP="$group_name" EXPECTED_OWNER="$owner_code" python3 - <<'PY'
import json
import os
pairs = json.loads(os.environ["RESPONSE"])["KeyPairs"]
tags = {item["Key"]: item["Value"] for item in pairs[0].get("Tags", [])}
expected = {"course": "yuntech-115-1", "week": "w03", "group": os.environ["EXPECTED_GROUP"], "owner": os.environ["EXPECTED_OWNER"]}
if any(tags.get(key) != value for key, value in expected.items()):
    raise SystemExit("key pair ownership tags do not match resources.json")
PY
            ;;
        *)
            echo "ERROR: unknown resource type $resource_type" >&2
            exit 1
            ;;
    esac
}

if "$stop_only"; then
    verify_tags instance "$instance_id"
    echo "Resource to stop: EC2 instance $instance_id in $vpc_id / $subnet_id"
    printf 'Type STOP to continue: '
    read -r approval
    [[ "$approval" == "STOP" ]] || { echo "Cancelled; no AWS resources changed."; exit 1; }
    aws_json ec2 stop-instances --instance-ids "$instance_id" >/dev/null
    aws_json ec2 wait instance-stopped --instance-ids "$instance_id" >/dev/null
    python3 - "$RESOURCES_FILE" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
data["public_ip"] = None
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
path.chmod(0o600)
PY
    echo "Confirmed: $instance_id is stopped; security group and key pair were retained."
    exit 0
fi

verify_tags instance "$instance_id"
verify_tags security-group "$security_group_id"
verify_tags key-pair "$key_pair_id"

echo "Resources to delete/reclaim:"
printf '  EC2 instance:   %s (terminate)\n' "$instance_id"
printf '  Security Group: %s (delete)\n' "$security_group_id"
printf '  Key pair:       %s (delete)\n' "$key_pair_id"
printf '  Retained:       VPC %s, subnet %s\n' "$vpc_id" "$subnet_id"
printf 'Type DELETE to continue: '
read -r approval
[[ "$approval" == "DELETE" ]] || { echo "Cancelled; no AWS resources changed."; exit 1; }

aws_json ec2 terminate-instances --instance-ids "$instance_id" >/dev/null
aws_json ec2 wait instance-terminated --instance-ids "$instance_id" >/dev/null
aws_json ec2 delete-security-group --group-id "$security_group_id" >/dev/null
aws_json ec2 delete-key-pair --key-pair-id "$key_pair_id" >/dev/null
expect_absent ec2 describe-security-groups --group-ids "$security_group_id"
expect_absent ec2 describe-key-pairs --key-pair-ids "$key_pair_id"

instance_state=$(aws_json ec2 describe-instances --instance-ids "$instance_id")
INSTANCE_STATE="$instance_state" python3 - <<'PY'
import json
import os

instances = json.loads(os.environ["INSTANCE_STATE"])["Reservations"][0]["Instances"]
state = instances[0]["State"]["Name"]
if state != "terminated":
    raise SystemExit(f"instance is not terminated: {state}")
print("Confirmed instance state: terminated")
PY

python3 - "$RESOURCES_FILE" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
print("Reclaimed resources verified by ID:")
print(f"  EC2 instance: {data['instance_id']}")
print(f"  Security Group: {data['security_group_id']}")
print(f"  Key pair: {data['key_pair_id']}")
path.unlink()
PY
echo "Confirmed: dedicated instance, security group and key pair were reclaimed. VPC and subnet were retained."
