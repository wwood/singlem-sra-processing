#!/bin/bash
#
# fix_master_eks_permissions.sh
#
# Give the EC2 "master" node (the one that runs `argo submit` / `kubectl`
# against the sandpiper EKS cluster) the permissions it needs, by attaching a
# job-submitter IAM role to the instance AND granting that role cluster-admin
# access inside EKS.
#
# This scripts the manual runbook that fixed the "permission problems" when
# submitting jobs from a freshly-created master instance. Two separate things
# have to line up:
#
#   1. AWS/IAM side  - the instance must carry an instance profile whose role
#                      can call `eks:DescribeCluster` (so `aws eks
#                      update-kubeconfig` works) and assume nothing else.
#   2. Kubernetes side - EKS must map that IAM role to a k8s identity via an
#                      *access entry* + the AmazonEKSClusterAdminPolicy access
#                      policy. Attaching the role to the instance is NOT enough
#                      on its own; without the access entry kubectl returns
#                      "error: You must be logged in to the server".
#
# Everything here is idempotent: re-running it reconciles state rather than
# failing on things that already exist.
#
# NOTE: this is a DIFFERENT approach from setup_aws.bash Step 3, which gives the
# master an AdministratorAccess role (sandpiper-master-admin). This script uses
# a narrowly-scoped job-submitter role instead. Pick one; don't attach both.
#
# Prereqs: working AWS credentials on THIS machine (`aws sts get-caller-identity`
# must succeed - refresh SSO / `aws configure` if it says ExpiredToken), plus
# permission to manage IAM roles/instance profiles, EC2 instance profiles, and
# EKS access entries.
#
# Usage:
#   ./fix_master_eks_permissions.sh                      # defaults below
#   ./fix_master_eks_permissions.sh --host ec2-3-89-47-232.compute-1.amazonaws.com
#   ./fix_master_eks_permissions.sh --instance-id i-0025f2600c82a1a99
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
ROLE_NAME="${ROLE_NAME:-woodcrob-sandpiper-eks-job-submitter-role1}"
INSTANCE_PROFILE_NAME="${INSTANCE_PROFILE_NAME:-woodcrob-eks-master-node}"
ACCESS_POLICY_ARN="${ACCESS_POLICY_ARN:-arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy}"

# The master instance to fix, identified EITHER by --instance-id OR by --host
# (public DNS name or public/private IP). Default host is the current master.
INSTANCE_ID="${INSTANCE_ID:-}"
HOST="${HOST:-ec2-3-89-47-232.compute-1.amazonaws.com}"

# Whether to (idempotently) add an inline policy granting eks:DescribeCluster to
# the role. Required so `aws eks update-kubeconfig` works from the master; the
# EKS access entry alone does NOT grant this AWS-API call. Set 0 if the role
# already has it via some other managed policy.
ADD_DESCRIBE_POLICY="${ADD_DESCRIBE_POLICY:-1}"

# Whether to (idempotently) add an inline policy granting the role S3 access to
# ${BUCKET}. Required for the master to list/read/write pipeline objects (e.g.
# `s5cmd ls s3://.../multi_batch*/sketches/*`); without it those calls 403 with
# "no identity-based policy allows the s3:ListBucket action". Set 0 to skip.
ADD_S3_POLICY="${ADD_S3_POLICY:-1}"
BUCKET="${BUCKET:-woodcrob-sandpiper-us-east-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance-id) INSTANCE_ID="${2:?--instance-id needs a value}"; shift 2 ;;
    --host)        HOST="${2:?--host needs a value}"; shift 2 ;;
    --region)      REGION="${2:?--region needs a value}"; shift 2 ;;
    --cluster)     CLUSTER="${2:?--cluster needs a value}"; shift 2 ;;
    --role-name)   ROLE_NAME="${2:?--role-name needs a value}"; shift 2 ;;
    --instance-profile-name) INSTANCE_PROFILE_NAME="${2:?needs a value}"; shift 2 ;;
    -h|--help)
      sed -n '2,40p' "$0"; exit 0 ;;
    *) die "Unknown argument: $1 (try --help)" ;;
  esac
done

command -v aws >/dev/null 2>&1 || die "aws CLI not found."
aws sts get-caller-identity >/dev/null 2>&1 \
  || die "AWS credentials not working (ExpiredToken?). Refresh SSO / 'aws configure' and retry."

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
log "Account ${ACCOUNT_ID}, region ${REGION}, cluster ${CLUSTER}"
log "Role ${ROLE_ARN}"
log "Instance profile ${INSTANCE_PROFILE_NAME}"

###############################################################################
# Step A. Resolve the target instance ID
###############################################################################
if [[ -z "${INSTANCE_ID}" ]]; then
  log "Step A: Resolving instance from host '${HOST}'"
  # ec2-3-89-47-232.compute-1.amazonaws.com  ->  3.89.47.232
  MAYBE_IP="${HOST}"
  if [[ "${HOST}" =~ ^ec2-([0-9]+-[0-9]+-[0-9]+-[0-9]+)\. ]]; then
    MAYBE_IP="${BASH_REMATCH[1]//-/.}"
  fi
  # Try, in order: public IP, private IP, then the DNS name itself.
  for filter in "ip-address" "private-ip-address"; do
    INSTANCE_ID="$(aws ec2 describe-instances --region "${REGION}" \
      --filters "Name=${filter},Values=${MAYBE_IP}" \
                "Name=instance-state-name,Values=pending,running,stopping,stopped" \
      --query 'Reservations[].Instances[].InstanceId | [0]' --output text 2>/dev/null || true)"
    [[ -n "${INSTANCE_ID}" && "${INSTANCE_ID}" != "None" ]] && break
    INSTANCE_ID=""
  done
  if [[ -z "${INSTANCE_ID}" ]]; then
    INSTANCE_ID="$(aws ec2 describe-instances --region "${REGION}" \
      --filters "Name=dns-name,Values=${HOST}" \
                "Name=instance-state-name,Values=pending,running,stopping,stopped" \
      --query 'Reservations[].Instances[].InstanceId | [0]' --output text 2>/dev/null || true)"
  fi
  [[ -n "${INSTANCE_ID}" && "${INSTANCE_ID}" != "None" ]] \
    || die "Could not resolve an instance from host '${HOST}' (tried IP ${MAYBE_IP} and DNS). Pass --instance-id."
fi
log "Target instance: ${INSTANCE_ID}"

###############################################################################
# Step B. Ensure the IAM role exists (EC2 trust) and can DescribeCluster
###############################################################################
log "Step B: Ensuring IAM role ${ROLE_NAME}"
if ! aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  warn "Role ${ROLE_NAME} does not exist; creating it with an EC2 trust policy."
  aws iam create-role --role-name "${ROLE_NAME}" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "ec2.amazonaws.com"},
        "Action": "sts:AssumeRole"
      }]
    }' >/dev/null
else
  echo "Role ${ROLE_NAME} already exists."
fi

if [[ "${ADD_DESCRIBE_POLICY}" == "1" ]]; then
  echo "Ensuring inline policy 'eks-describe-cluster' on the role."
  aws iam put-role-policy --role-name "${ROLE_NAME}" \
    --policy-name eks-describe-cluster \
    --policy-document "$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["eks:DescribeCluster", "eks:ListClusters"],
      "Resource": "*"
    }
  ]
}
JSON
)"
fi

if [[ "${ADD_S3_POLICY}" == "1" ]]; then
  echo "Ensuring inline policy 's3-${BUCKET}' on the role."
  # ListBucket is granted on the bucket ARN; object actions on the /* ARN. This
  # mirrors cloud/argo/policy.json (the S3 access the pipeline uses).
  aws iam put-role-policy --role-name "${ROLE_NAME}" \
    --policy-name "s3-${BUCKET}" \
    --policy-document "$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:GetObjectTagging", "s3:PutObjectTagging"],
      "Resource": "arn:aws:s3:::${BUCKET}/*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": "arn:aws:s3:::${BUCKET}"
    }
  ]
}
JSON
)"
fi

###############################################################################
# Step C. Ensure the instance profile exists and contains the role
###############################################################################
log "Step C: Ensuring instance profile ${INSTANCE_PROFILE_NAME} contains ${ROLE_NAME}"
if ! aws iam get-instance-profile --instance-profile-name "${INSTANCE_PROFILE_NAME}" >/dev/null 2>&1; then
  echo "Creating instance profile ${INSTANCE_PROFILE_NAME}."
  aws iam create-instance-profile --instance-profile-name "${INSTANCE_PROFILE_NAME}" >/dev/null
fi
# An instance profile can hold at most one role. Add ours only if absent.
CURRENT_PROFILE_ROLE="$(aws iam get-instance-profile \
  --instance-profile-name "${INSTANCE_PROFILE_NAME}" \
  --query 'InstanceProfile.Roles[0].RoleName' --output text 2>/dev/null || true)"
if [[ "${CURRENT_PROFILE_ROLE}" == "${ROLE_NAME}" ]]; then
  echo "Role already attached to the instance profile."
elif [[ -n "${CURRENT_PROFILE_ROLE}" && "${CURRENT_PROFILE_ROLE}" != "None" ]]; then
  warn "Instance profile currently holds a different role (${CURRENT_PROFILE_ROLE}); replacing it with ${ROLE_NAME}."
  aws iam remove-role-from-instance-profile \
    --instance-profile-name "${INSTANCE_PROFILE_NAME}" --role-name "${CURRENT_PROFILE_ROLE}"
  aws iam add-role-to-instance-profile \
    --instance-profile-name "${INSTANCE_PROFILE_NAME}" --role-name "${ROLE_NAME}"
  sleep 10   # let IAM propagate before EC2 references it
else
  aws iam add-role-to-instance-profile \
    --instance-profile-name "${INSTANCE_PROFILE_NAME}" --role-name "${ROLE_NAME}"
  sleep 10
fi

###############################################################################
# Step D. Attach the instance profile to the EC2 instance
###############################################################################
log "Step D: Attaching instance profile to ${INSTANCE_ID}"
ASSOC_JSON="$(aws ec2 describe-iam-instance-profile-associations --region "${REGION}" \
  --filters "Name=instance-id,Values=${INSTANCE_ID}" \
  --query 'IamInstanceProfileAssociations[?State==`associated` || State==`associating`] | [0].{Id:AssociationId,Arn:IamInstanceProfile.Arn}' \
  --output json 2>/dev/null || echo 'null')"
ASSOC_ID="$(echo "${ASSOC_JSON}" | sed -n 's/.*"Id": *"\([^"]*\)".*/\1/p')"
ASSOC_ARN="$(echo "${ASSOC_JSON}" | sed -n 's/.*"Arn": *"\([^"]*\)".*/\1/p')"

if [[ "${ASSOC_ARN}" == *"instance-profile/${INSTANCE_PROFILE_NAME}" ]]; then
  echo "Instance already carries instance profile ${INSTANCE_PROFILE_NAME}; nothing to change."
elif [[ -n "${ASSOC_ID}" ]]; then
  echo "Replacing existing association ${ASSOC_ID} (was ${ASSOC_ARN:-unknown})."
  aws ec2 replace-iam-instance-profile-association --region "${REGION}" \
    --association-id "${ASSOC_ID}" \
    --iam-instance-profile "Name=${INSTANCE_PROFILE_NAME}" >/dev/null
else
  echo "No existing association; associating instance profile."
  aws ec2 associate-iam-instance-profile --region "${REGION}" \
    --instance-id "${INSTANCE_ID}" \
    --iam-instance-profile "Name=${INSTANCE_PROFILE_NAME}" >/dev/null
fi

###############################################################################
# Step E. Grant the role cluster access inside EKS
###############################################################################
log "Step E: Ensuring EKS access entry + cluster-admin policy for the role"
if aws eks describe-access-entry --region "${REGION}" \
      --cluster-name "${CLUSTER}" --principal-arn "${ROLE_ARN}" >/dev/null 2>&1; then
  echo "Access entry for ${ROLE_NAME} already exists."
else
  echo "Creating access entry for ${ROLE_NAME}."
  aws eks create-access-entry --region "${REGION}" \
    --cluster-name "${CLUSTER}" --principal-arn "${ROLE_ARN}" >/dev/null
fi

echo "Associating ${ACCESS_POLICY_ARN} (cluster scope)."
aws eks associate-access-policy --region "${REGION}" \
  --cluster-name "${CLUSTER}" \
  --principal-arn "${ROLE_ARN}" \
  --policy-arn "${ACCESS_POLICY_ARN}" \
  --access-scope type=cluster >/dev/null

###############################################################################
# Step F. Report
###############################################################################
log "Done. Verification:"
cat <<EOF

Access entries on ${CLUSTER}:
  aws eks list-access-entries --cluster-name ${CLUSTER} --region ${REGION}

The instance profile change takes effect on the instance within ~1-2 min (no
reboot needed). Then, ON THE MASTER NODE (${HOST}):

  aws sts get-caller-identity          # should show .../${ROLE_NAME}/i-...
  aws eks update-kubeconfig --name ${CLUSTER} --region ${REGION}
  kubectl get nodes
  argo list -n argo

If kubectl still says "You must be logged in to the server", the instance is
probably still using cached old credentials - wait a minute (or re-run
'aws eks update-kubeconfig') and try again.
EOF
