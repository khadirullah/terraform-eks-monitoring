#!/usr/bin/env bash
# ──────────────────────────────────────────────
# destroy.sh - Tear the whole thing down
#
# Order matters. Kubernetes Services of type
# LoadBalancer create ELBs that Terraform did
# not create and does not know about. Destroying
# the VPC before those ELBs are gone leaves them
# running, billing, and holding the subnets so
# the VPC delete hangs. Delete Kubernetes first.
# ──────────────────────────────────────────────

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[ok]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[->]${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

command -v terraform >/dev/null 2>&1 || err "Terraform is not installed"
command -v kubectl >/dev/null 2>&1   || err "kubectl is not installed"
command -v aws >/dev/null 2>&1       || err "AWS CLI is not installed"

cd "$PROJECT_DIR/terraform"

if [ ! -f "terraform.tfstate" ] && [ ! -d ".terraform" ]; then
    warn "No Terraform state here. Either it was never applied, or state lives elsewhere."
    warn "Check the AWS console for an EKS cluster before assuming nothing is running."
    exit 1
fi

CLUSTER_NAME="$(terraform output -raw cluster_name 2>/dev/null || echo "")"
AWS_REGION="$(terraform output -raw aws_region 2>/dev/null || echo "ap-south-1")"

echo ""
echo "This destroys the EKS cluster, the node group, the NAT gateway and the VPC."
echo "Cluster: ${CLUSTER_NAME:-unknown}"
echo "Region:  ${AWS_REGION}"
echo ""
read -r -p "Type 'destroy' to continue: " CONFIRM
[ "$CONFIRM" = "destroy" ] || err "Aborted."

# ── Step 1: Kubernetes resources, so AWS releases the ELBs ──
if [ -n "$CLUSTER_NAME" ] && aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    info "Step 1/3: Removing Kubernetes resources that hold AWS load balancers"
    aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null

    LB_SVCS="$(kubectl get svc --all-namespaces \
        -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"

    if [ -n "$LB_SVCS" ]; then
        warn "LoadBalancer services found, deleting them first:"
        echo "$LB_SVCS"
        kubectl delete svc --all-namespaces --field-selector spec.type=LoadBalancer --wait=true || true
        info "Waiting 45s for AWS to release the load balancers"
        sleep 45
    else
        log "No LoadBalancer services, nothing holding an ELB"
    fi

    kubectl delete namespace monitoring --wait=true --timeout=180s 2>/dev/null || true
    log "Kubernetes resources removed"
else
    warn "Cluster not reachable or already gone, skipping the Kubernetes step"
fi

# ── Step 2: Terraform ──
info "Step 2/3: terraform destroy"
terraform destroy -auto-approve
log "Terraform resources destroyed"

# ── Step 3: Check nothing was left behind ──
info "Step 3/3: Checking for orphaned resources that still cost money"

ORPHAN_LB="$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
    --query "LoadBalancers[?contains(LoadBalancerName, 'k8s')].LoadBalancerName" --output text 2>/dev/null || true)"
ORPHAN_CLB="$(aws elb describe-load-balancers --region "$AWS_REGION" \
    --query "LoadBalancerDescriptions[].LoadBalancerName" --output text 2>/dev/null || true)"
ORPHAN_EIP="$(aws ec2 describe-addresses --region "$AWS_REGION" \
    --query "Addresses[?AssociationId==null].PublicIp" --output text 2>/dev/null || true)"
ORPHAN_VOL="$(aws ec2 describe-volumes --region "$AWS_REGION" \
    --filters Name=status,Values=available \
    --query "Volumes[].VolumeId" --output text 2>/dev/null || true)"

FOUND=0
[ -n "$ORPHAN_LB" ]  && { warn "Load balancers still present: $ORPHAN_LB"; FOUND=1; }
[ -n "$ORPHAN_CLB" ] && { warn "Classic load balancers still present: $ORPHAN_CLB"; FOUND=1; }
[ -n "$ORPHAN_EIP" ] && { warn "Unattached Elastic IPs (these bill hourly): $ORPHAN_EIP"; FOUND=1; }
[ -n "$ORPHAN_VOL" ] && { warn "Unattached EBS volumes: $ORPHAN_VOL"; FOUND=1; }

echo ""
if [ "$FOUND" -eq 1 ]; then
    warn "Something survived the destroy. Delete the above by hand or it keeps billing."
    warn "Then check the console: EC2, EKS, VPC, and the Billing page tomorrow."
    exit 1
fi

log "Nothing orphaned in ${AWS_REGION}."
echo ""
echo "Check the AWS Billing console tomorrow anyway. Charges appear late,"
echo "and an empty region today is not proof of a zero bill."
echo ""
