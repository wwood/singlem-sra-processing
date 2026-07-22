#!/bin/bash
#
# teardown_aws.bash
#
# Tear down the sandpiper compute stack created by setup_aws.bash + eksctl:
#   1. the EKS cluster `sandpiper` (which deletes ALL its nodegroups - including
#      the self-managed weebill-m7a spot fleet - plus addons and the eksctl-created
#      VPC/subnets/NAT/CloudFormation stacks); and
#   2. the EC2 "master" node (the t2.medium that runs `argo submit` / `kubectl`).
# Optionally (--clean-iam) it also removes the IAM instance profile + role that
# fix_master_eks_permissions.sh attached to the master.
#
# This is the inverse of setup_aws.bash. It is DESTRUCTIVE and OUTWARD-FACING:
# it terminates instances and deletes cloud infrastructure. It requires an
# explicit confirmation (type the cluster name, or pass --yes).
#
# What it does NOT touch:
#   * S3. All results (sketches/profiles/logs under woodcrob-sandpiper-us-east-1)
#     are left completely alone - teardown removes compute only.
#   * Anything not created for this project (other clusters, other instances).
#
# Everything here is idempotent: re-running after a partial teardown reconciles
# (already-deleted things are treated as success, not errors). If the cluster
# CloudFormation stack gets stuck in DELETE_FAILED because a non-eksctl resource
# (typically a GuardDuty EKS Runtime Monitoring VPC endpoint) pins the private
# subnets, the script deletes that endpoint + its orphaned ENIs and retries the
# stack automatically.
#
# Prereqs: working AWS credentials on THIS machine (`aws sts get-caller-identity`
# must succeed - refresh SSO / `aws configure` if it says ExpiredToken), eksctl,
# and permission to delete EKS clusters, terminate EC2 instances, and (for
# --clean-iam) manage IAM roles/instance profiles.
#
# Usage:
#   ./teardown_aws.bash --dry-run                 # print every command, change nothing
#   ./teardown_aws.bash                           # interactive confirm, then tear down
#   ./teardown_aws.bash --yes                     # skip the confirmation prompt
#   ./teardown_aws.bash --instance-id i-0abc...   # name the master explicitly
#   ./teardown_aws.bash --host ec2-3-89-47-232.compute-1.amazonaws.com
#   ./teardown_aws.bash --keep-master             # delete cluster only
#   ./teardown_aws.bash --keep-cluster            # terminate master only
#   ./teardown_aws.bash --keep-iam                # leave the master's IAM role/profile in place
#
set -euo pipefail

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

###############################################################################
# Configuration (env-overridable; some also settable via flags)
###############################################################################
REGION="${REGION:-us-east-1}"
CLUSTER="${CLUSTER:-sandpiper}"

# IAM artifacts created by fix_master_eks_permissions.sh (only deleted with
# --clean-iam). Kept in sync with that script's defaults.
ROLE_NAME="${ROLE_NAME:-woodcrob-sandpiper-eks-job-submitter-role1}"
INSTANCE_PROFILE_NAME="${INSTANCE_PROFILE_NAME:-woodcrob-eks-master-node}"

# The master instance to terminate, identified EITHER by --instance-id OR by
# --host (public DNS name or public/private IP), OR discovered by instance type.
INSTANCE_ID="${INSTANCE_ID:-}"
HOST="${HOST:-}"
MASTER_INSTANCE_TYPE="${MASTER_INSTANCE_TYPE:-t2.medium}"

# Behaviour toggles
DRY_RUN=0
ASSUME_YES=0
KEEP_CLUSTER=0
KEEP_MASTER=0
CLEAN_IAM=1   # delete the master's IAM role/instance profile by default; --keep-iam opts out
# Skip draining pods when deleting nodegroups. Safe here: the weebill workflow is
# idempotent/resumable (a killed pod just re-runs and skips completed accessions),
# and we're deleting everything anyway. Set NODEGROUP_EVICTION=1 to drain instead.
NODEGROUP_EVICTION="${NODEGROUP_EVICTION:-0}"

###############################################################################
# Argument parsing
###############################################################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)       DRY_RUN=1 ;;
    --yes|-y)        ASSUME_YES=1 ;;
    --keep-cluster)  KEEP_CLUSTER=1 ;;
    --keep-master)   KEEP_MASTER=1 ;;
    --keep-iam)      CLEAN_IAM=0 ;;
    --instance-id)   INSTANCE_ID="${2:?--instance-id needs a value}"; shift ;;
    --host)          HOST="${2:?--host needs a value}"; shift ;;
    --region)        REGION="${2:?--region needs a value}"; shift ;;
    --cluster)       CLUSTER="${2:?--cluster needs a value}"; shift ;;
    -h|--help)       grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)               die "Unknown argument: $1 (see --help)" ;;
  esac
  shift
done

# run <cmd...> : execute, or just print it under --dry-run.
run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '    \033[2m[dry-run] %s\033[0m\n' "$*"
  else
    "$@"
  fi
}

###############################################################################
# Preflight
###############################################################################
command -v aws    >/dev/null 2>&1 || die "aws CLI not found on PATH."
[[ "$KEEP_CLUSTER" == "1" ]] || command -v eksctl >/dev/null 2>&1 || die "eksctl not found on PATH (needed to delete the cluster)."

log "Checking AWS credentials"
CALLER="$(aws sts get-caller-identity --query Arn --output text 2>&1)" \
  || die "AWS credentials not usable ($CALLER). Refresh SSO / aws configure."
echo "    Caller: $CALLER"
echo "    Region: $REGION   Cluster: $CLUSTER"

###############################################################################
# Resolve the master instance ID (unless we're keeping it)
###############################################################################
if [[ "$KEEP_MASTER" != "1" ]]; then
  if [[ -z "$INSTANCE_ID" && -n "$HOST" ]]; then
    log "Resolving master instance from --host $HOST"
    # Strip an ec2-A-B-C-D... public-DNS name down to its A.B.C.D IP if needed.
    ip=""
    if [[ "$HOST" =~ ^ec2-([0-9]+)-([0-9]+)-([0-9]+)-([0-9]+)\. ]]; then
      ip="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}.${BASH_REMATCH[4]}"
    fi
    for filt in "ip-address,$ip" "private-ip-address,$HOST" "dns-name,$HOST" "private-dns-name,$HOST"; do
      key="${filt%%,*}"; val="${filt#*,}"; [[ -n "$val" ]] || continue
      INSTANCE_ID="$(aws ec2 describe-instances --region "$REGION" \
        --filters "Name=$key,Values=$val" "Name=instance-state-name,Values=running,stopped" \
        --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)"
      [[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]] && break
    done
    [[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]] || die "Could not resolve an instance from --host $HOST. Pass --instance-id."
  fi

  if [[ -z "$INSTANCE_ID" ]]; then
    log "Discovering master instance by type ($MASTER_INSTANCE_TYPE)"
    mapfile -t FOUND < <(aws ec2 describe-instances --region "$REGION" \
      --filters "Name=instance-type,Values=$MASTER_INSTANCE_TYPE" "Name=instance-state-name,Values=running,stopped" \
      --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null | tr '\t' '\n' | sed '/^$/d')
    case "${#FOUND[@]}" in
      0) warn "No running/stopped $MASTER_INSTANCE_TYPE instance found - nothing to terminate. Use --instance-id if it's a different type."
         KEEP_MASTER=1 ;;
      1) INSTANCE_ID="${FOUND[0]}" ;;
      *) die "Found ${#FOUND[@]} $MASTER_INSTANCE_TYPE instances (${FOUND[*]}). Pass --instance-id to pick one." ;;
    esac
  fi
  [[ "$KEEP_MASTER" == "1" ]] || echo "    Master instance: $INSTANCE_ID"
fi

###############################################################################
# Confirmation gate
###############################################################################
log "Teardown plan"
[[ "$KEEP_CLUSTER" == "1" ]] && echo "    - EKS cluster '$CLUSTER': KEEP" \
                             || echo "    - EKS cluster '$CLUSTER' + all nodegroups + VPC: DELETE"
[[ "$KEEP_MASTER"  == "1" ]] && echo "    - Master EC2 instance: KEEP" \
                             || echo "    - Master EC2 instance '$INSTANCE_ID': TERMINATE"
[[ "$CLEAN_IAM"    == "1" ]] && echo "    - IAM role '$ROLE_NAME' + instance profile '$INSTANCE_PROFILE_NAME': DELETE (pass --keep-iam to keep)" \
                             || echo "    - IAM role/instance profile: KEEP"
echo "    - S3 data: UNTOUCHED"

if [[ "$DRY_RUN" != "1" && "$ASSUME_YES" != "1" ]]; then
  printf '\n\033[1;31mType the cluster name (%s) to confirm teardown: \033[0m' "$CLUSTER"
  read -r reply
  [[ "$reply" == "$CLUSTER" ]] || die "Confirmation did not match. Aborting; nothing deleted."
fi

###############################################################################
# reconcile_cluster_stack: fix a DELETE_FAILED eksctl cluster stack.
#
# `eksctl delete cluster` deletes the control plane and its own CloudFormation
# resources, but it does NOT own things other AWS services auto-create inside the
# cluster VPC. The common one is the GuardDuty EKS Runtime Monitoring VPC endpoint
# (com.amazonaws.<region>.guardduty-data): its interface ENIs live in the private
# subnets, so those subnets (and hence the VPC and the whole stack) fail to delete
# with "has dependencies and cannot be deleted", leaving the stack DELETE_FAILED.
# We delete any such leftover VPC endpoints + orphaned ENIs, then retry the stack.
###############################################################################
reconcile_cluster_stack() {
  local stack="eksctl-${CLUSTER}-cluster"
  local status
  status="$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$stack" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || true)"
  [[ -z "$status" || "$status" == "None" ]] && { log "Cluster stack '$stack' is gone - nothing to reconcile."; return 0; }
  if [[ "$status" != "DELETE_FAILED" && "$status" != "DELETE_IN_PROGRESS" ]]; then
    warn "Cluster stack '$stack' is in state '$status' (not a delete state); leaving it alone."; return 0
  fi
  warn "Cluster stack '$stack' is $status - reconciling leftover VPC dependencies."

  # Resolve the VPC id (captured before eksctl ran, else read from the stack output).
  [[ -z "${VPC_ID:-}" || "$VPC_ID" == "None" ]] && VPC_ID="$(aws cloudformation describe-stacks \
    --region "$REGION" --stack-name "$stack" \
    --query "Stacks[0].Outputs[?OutputKey=='VPC'].OutputValue" --output text 2>/dev/null || true)"

  if [[ -n "${VPC_ID:-}" && "$VPC_ID" != "None" ]]; then
    # Delete every VPC endpoint in the VPC (this public cluster creates none of its
    # own, so any present - e.g. GuardDuty - is a non-eksctl leftover safe to remove).
    for ep in $(aws ec2 describe-vpc-endpoints --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'VpcEndpoints[].VpcEndpointId' --output text 2>/dev/null || true); do
      warn "Deleting leftover VPC endpoint $ep (releases its ENIs)"
      run aws ec2 delete-vpc-endpoints --region "$REGION" --vpc-endpoint-ids "$ep" >/dev/null
    done
    # Delete any now-detached (available) ENIs still sitting in the VPC.
    for eni in $(aws ec2 describe-network-interfaces --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available" \
        --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null || true); do
      run aws ec2 delete-network-interface --region "$REGION" --network-interface-id "$eni" 2>/dev/null || true
    done
    # Delete leftover non-default security groups (GuardDuty leaves a
    # GuardDutyManagedSecurityGroup-* behind that blocks the VPC delete). The
    # eksctl-owned SGs delete with the stack; only foreign ones remain here.
    for sg in $(aws ec2 describe-security-groups --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null || true); do
      warn "Deleting leftover security group $sg"
      run aws ec2 delete-security-group --region "$REGION" --group-id "$sg" 2>/dev/null || true
    done
    # Let AWS finish releasing the endpoint ENIs before CloudFormation retries the subnets.
    [[ "$DRY_RUN" == "1" ]] || { echo "    waiting 45s for ENIs to clear..."; sleep 45; }
  fi

  log "Retrying deletion of stack '$stack'"
  run aws cloudformation delete-stack --region "$REGION" --stack-name "$stack"
  if [[ "$DRY_RUN" != "1" ]]; then
    aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$stack" 2>/dev/null \
      && log "Cluster stack deleted." \
      || warn "Stack '$stack' still not fully deleted - inspect the blocking resource in the CloudFormation console."
  fi
}

###############################################################################
# Step 1: delete the EKS cluster (drains + deletes nodegroups, addons, VPC)
###############################################################################
if [[ "$KEEP_CLUSTER" != "1" ]]; then
  CLUSTER_STACK="eksctl-${CLUSTER}-cluster"
  # Capture the VPC id up-front so we can clean up VPC-level leftovers even after
  # eksctl has deleted the control plane (which removes the stack outputs).
  VPC_ID="$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$CLUSTER_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='VPC'].OutputValue" --output text 2>/dev/null || true)"

  if eksctl get cluster --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1; then
    log "Deleting EKS cluster '$CLUSTER' (this deletes the nodegroups and VPC too; can take ~15-25 min)"
    evict_flag="--disable-nodegroup-eviction"
    [[ "$NODEGROUP_EVICTION" == "1" ]] && evict_flag=""
    # Don't let an eksctl error abort the script: a transient CloudFormation/network
    # blip (or the GuardDuty-endpoint blocker) leaves a DELETE_FAILED stack that we
    # reconcile below rather than bailing out.
    run eksctl delete cluster --name "$CLUSTER" --region "$REGION" $evict_flag --wait \
      || warn "eksctl delete cluster returned an error; reconciling any leftover stack resources."
  else
    warn "Control plane '$CLUSTER' not found - already deleted; checking for a leftover CFN stack."
  fi

  # Clean up a DELETE_FAILED / stuck cluster stack (GuardDuty endpoint etc.).
  [[ "$DRY_RUN" == "1" ]] && log "(dry-run) would reconcile a leftover cluster stack if present"
  reconcile_cluster_stack
fi

###############################################################################
# Step 2: terminate the master EC2 instance
###############################################################################
if [[ "$KEEP_MASTER" != "1" ]]; then
  log "Terminating master instance $INSTANCE_ID"
  run aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
    --query 'TerminatingInstances[].{Id:InstanceId,Prev:PreviousState.Name,Now:CurrentState.Name}' --output table
fi

###############################################################################
# Step 3 (opt-in): delete the master's IAM instance profile + role
###############################################################################
# The EKS access entry that fix_master_eks_permissions.sh created is cluster-scoped
# and is destroyed with the cluster in Step 1, so there's nothing to remove here for
# it. We only tear down the instance profile and role.
if [[ "$CLEAN_IAM" == "1" ]]; then
  log "Cleaning up IAM: instance profile '$INSTANCE_PROFILE_NAME' and role '$ROLE_NAME'"

  # Detach the role from the instance profile (required before either can be deleted).
  if aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null 2>&1; then
    roles="$(aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" \
      --query 'InstanceProfile.Roles[].RoleName' --output text 2>/dev/null || true)"
    for r in $roles; do
      run aws iam remove-role-from-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" --role-name "$r"
    done
    run aws iam delete-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME"
  else
    warn "Instance profile '$INSTANCE_PROFILE_NAME' not found - skipping."
  fi

  # Delete the role: its inline policies must go first, then any attached managed policies.
  if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    for pol in $(aws iam list-role-policies --role-name "$ROLE_NAME" --query 'PolicyNames[]' --output text 2>/dev/null || true); do
      run aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "$pol"
    done
    for arn in $(aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true); do
      run aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$arn"
    done
    run aws iam delete-role --role-name "$ROLE_NAME"
  else
    warn "Role '$ROLE_NAME' not found - skipping."
  fi
fi

###############################################################################
# Done
###############################################################################
log "Teardown complete"
[[ "$DRY_RUN" == "1" ]] && echo "    (dry-run: nothing was actually changed)"
echo "    S3  NOT touched."
[[ "$CLEAN_IAM" == "1" ]] || echo "    IAM role/instance profile left in place (--keep-iam was set)."
