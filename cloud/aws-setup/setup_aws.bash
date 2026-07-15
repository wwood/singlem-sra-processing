#!/bin/bash
#
# setup_weebill.bash
#
# Automates the setup of the "weebill" (sracat_weebill:v3) SingleM SRA
# processing pipeline on AWS EKS + Argo Workflows.
#
# This script is intended to be run from a *desktop/workstation* that already
# has AWS credentials and config set up (i.e. `aws sts get-caller-identity`
# works). It updates the local eksctl/kubectl/argo tooling, provisions the
# EKS cluster, installs Argo, wires up S3 credentials, and submits a test job.
#
# The script fails fast: any error, unset variable or failing pipe stage
# aborts execution immediately.
#
# Capacity is provisioned MANUALLY: the cluster starts with 0 worker nodes and
# the nodegroup is created with desiredCapacity 0. The Argo controller and the
# test workflows submitted here stay Pending until you scale a nodegroup up
# (see the Step 14 command printed at the end). The controller rollout waits
# are therefore non-fatal, and the test jobs are submitted without --watch so
# the script never blocks on missing capacity.
#
# A handful of steps in the original manual runbook were done via the AWS
# console (creating the EC2 master instance, pushing the docker image, and
# creating the S3 bucket). The EC2 master instance and the S3 bucket are now
# created programmatically here (Steps 3 and 5); the docker image is still a
# prerequisite and is only verified to exist.
#
# Usage:
#   ./setup_aws.bash \
#       --workflow-template cloud/argo/sra_weebill_workflow_template.yaml \
#       --ecr-image 656626576102.dkr.ecr.us-east-1.amazonaws.com/singlem/sracat_weebill:v2
#
#   SKIP_CLUSTER_CREATE=1 ./setup_aws.bash ...        # skip cluster creation on re-runs
#   ./setup_aws.bash --start-step 7 ...               # resume, running from Step 7 onward
#   SKIP_MASTER_INSTANCE=1 ./setup_aws.bash ...       # don't create the EC2 master node
#
# See the "How to run this for the weebill workflow" block printed by
# `./setup_aws.bash --help` for the exact weebill invocation.
#
# --workflow-template and --ecr-image are REQUIRED: the workflow template and
# the image it runs must be chosen explicitly and kept consistent with each
# other (the template runs the image you pass via --ecr-image).
#
# Steps are numbered (1, 2, 3, 5, 6, 7, 8, 9, 10, 11). --start-step N runs every
# step numbered >= N and skips the earlier ones, so a failed run can be resumed
# without repeating the (slow) cluster creation. The pre-flight checks always run.
#
set -euo pipefail

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $(basename "$0") --workflow-template <path> --ecr-image <uri> [options]

Required arguments:
  --workflow-template <path>  Argo workflow template YAML used to submit jobs
                              (e.g. cloud/argo/logan_workflow_template.yaml).
  --ecr-image <uri>           Container image URI the workflow runs; verified to
                              exist in ECR. Must match the image the template
                              runs (e.g.
                              656626576102.dkr.ecr.us-east-1.amazonaws.com/singlem/sracat_weebill:v2).

Options (defaults shown; may also be set via the matching environment variable):
  --region <r>                AWS region (us-east-1)
  --cluster-name <n>          EKS cluster name (sandpiper)
  --bucket <b>                S3 bucket (woodcrob-sandpiper-us-east-1)
  --nodegroup-template <p>    eksctl nodegroup config (cloud/argo/nodegroup_eks_template.yaml)
  --test-accession <acc>      SRA accession for the template test job (SRR8653040)
  --test-parameter KEY=VALUE  Parameter for the Step 10 smoke-test submission;
                              repeatable. If given, these fully replace the
                              default (SRA_accession_num=<test-accession>). Use
                              for templates needing extra parameters, e.g.
                              --test-parameter batch_name=smoke
                              --test-parameter reference_s3_uri=s3://...
  --start-step <N>            Run every step numbered >= N (skip earlier steps).
                              Steps: 1,2,3,5,6,7,8,9,10,11. Default 1 (all steps).
  --master-instance-type <t>  EC2 type for the master node (t2.medium)
  --master-key-name <k>       EC2 key pair name for the master node (woodcrob1)
  --skip-master-instance      Do not create the EC2 master node (Step 3)
  -h, --help                  Show this help and exit

Environment-only knobs for the master node (Step 3):
  MASTER_INSTANCE_NAME (sandpiper-master2), MASTER_ROLE_NAME (sandpiper-master-admin),
  MASTER_AMI (auto: latest Ubuntu 22.04), MASTER_VOLUME_SIZE_GB (20),
  MASTER_SECURITY_GROUP (sandpiper-master-ssh), MASTER_SSH_CIDR (0.0.0.0/0).

How to run this for the weebill workflow (cloud/argo/):
  ./setup_aws.bash \\
      --workflow-template cloud/argo/sra_weebill_workflow_template.yaml \\
      --ecr-image 656626576102.dkr.ecr.us-east-1.amazonaws.com/singlem/sracat_weebill:v2 \\
      --test-parameter SRA_accession_num=SRR8653040 \\
      --test-parameter batch_name=smoke-test \\
      --test-parameter ephemeral_storage_mb=20000 \\
      --test-parameter reference_s3_uri=s3://woodcrob-sandpiper-us-east-1/references/weebill/gtdb.sylref
  The weebill template needs all four parameters above (see
  sra_weebill_workflow_template.yaml). Bulk submission afterwards is driven by
  cloud/argo/slow_argo_submission_weebill.py (printed again at the end).
EOF
}

###############################################################################
# Configuration
###############################################################################
# Optional settings (env-overridable; may also be set via the flags below)
REGION="${REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-sandpiper}"
BUCKET="${BUCKET:-woodcrob-sandpiper-us-east-1}"
BOOTSTRAP_INSTANCE_TYPES="${BOOTSTRAP_INSTANCE_TYPES:-c7a.12xlarge}"
ARGO_WORKFLOWS_VERSION="${ARGO_WORKFLOWS_VERSION:-v3.7.6}"
ARGO_NAMESPACE="${ARGO_NAMESPACE:-argo}"
S3_SECRET_NAME="${S3_SECRET_NAME:-my-s3-credentials}"
NAMESPACE_PARALLELISM="${NAMESPACE_PARALLELISM:-3000}"
RETENTION_COMPLETED="${RETENTION_COMPLETED:-500}"
RETENTION_FAILED="${RETENTION_FAILED:-500}"
RETENTION_ERRORED="${RETENTION_ERRORED:-500}"
IO_NODEGROUP_NAME="${IO_NODEGROUP_NAME:-io-logan-mach2}"
IO_NODEGROUP_MAX="${IO_NODEGROUP_MAX:-100}"
TEST_SRA_ACCESSION="${TEST_SRA_ACCESSION:-SRR8653040}"
NODEGROUP_TEMPLATE="${NODEGROUP_TEMPLATE:-}"

# Step 3 EC2 master node. Created programmatically (was previously a manual
# console step). Set SKIP_MASTER_INSTANCE=1 to skip it entirely.
START_STEP="${START_STEP:-1}"
SKIP_MASTER_INSTANCE="${SKIP_MASTER_INSTANCE:-0}"
MASTER_INSTANCE_NAME="${MASTER_INSTANCE_NAME:-sandpiper-master2}"
MASTER_INSTANCE_TYPE="${MASTER_INSTANCE_TYPE:-t2.medium}"
MASTER_VOLUME_SIZE_GB="${MASTER_VOLUME_SIZE_GB:-20}"
MASTER_KEY_NAME="${MASTER_KEY_NAME:-woodcrob1}"
MASTER_ROLE_NAME="${MASTER_ROLE_NAME:-sandpiper-master-admin}"
MASTER_SECURITY_GROUP="${MASTER_SECURITY_GROUP:-sandpiper-master-ssh}"
MASTER_SSH_CIDR="${MASTER_SSH_CIDR:-0.0.0.0/0}"
MASTER_AMI="${MASTER_AMI:-}"       # empty => look up latest Ubuntu 22.04 via SSM
MASTER_REPO_URL="${MASTER_REPO_URL:-https://github.com/wwood/singlem-sra-processing/}"

# Required arguments (no defaults) - must be supplied on the command line.
WORKFLOW_TEMPLATE="${WORKFLOW_TEMPLATE:-}"
ECR_IMAGE="${ECR_IMAGE:-}"

# Parameters passed to the Step 10 smoke-test submission. Populated by
# repeated --test-parameter KEY=VALUE flags; if none are given, defaults to
# just SRA_accession_num below. Templates that require additional parameters
# (e.g. sra_multi_workflow_template.yaml needs batch_name / ephemeral_storage_mb
# / reference_s3_uri) should supply them explicitly with --test-parameter.
TEST_PARAMETERS=()

# Parse command-line arguments (override the above).
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workflow-template)  WORKFLOW_TEMPLATE="${2:?--workflow-template needs a value}"; shift 2 ;;
    --ecr-image)          ECR_IMAGE="${2:?--ecr-image needs a value}"; shift 2 ;;
    --region)             REGION="${2:?--region needs a value}"; shift 2 ;;
    --cluster-name)       CLUSTER_NAME="${2:?--cluster-name needs a value}"; shift 2 ;;
    --bucket)             BUCKET="${2:?--bucket needs a value}"; shift 2 ;;
    --nodegroup-template) NODEGROUP_TEMPLATE="${2:?--nodegroup-template needs a value}"; shift 2 ;;
    --test-accession)     TEST_SRA_ACCESSION="${2:?--test-accession needs a value}"; shift 2 ;;
    --test-parameter)     TEST_PARAMETERS+=("${2:?--test-parameter needs KEY=VALUE}"); shift 2 ;;
    --start-step)         START_STEP="${2:?--start-step needs a value}"; shift 2 ;;
    --master-instance-type) MASTER_INSTANCE_TYPE="${2:?--master-instance-type needs a value}"; shift 2 ;;
    --master-key-name)    MASTER_KEY_NAME="${2:?--master-key-name needs a value}"; shift 2 ;;
    --skip-master-instance) SKIP_MASTER_INSTANCE=1; shift ;;
    -h|--help)            usage; exit 0 ;;
    *) usage; die "Unknown argument: $1" ;;
  esac
done

# Enforce the required arguments.
[[ -n "${WORKFLOW_TEMPLATE}" ]] || { usage; die "Missing required argument: --workflow-template"; }
[[ -n "${ECR_IMAGE}" ]]         || { usage; die "Missing required argument: --ecr-image"; }

# --start-step must be a positive integer. Steps numbered >= START_STEP run.
[[ "${START_STEP}" =~ ^[0-9]+$ ]] || { usage; die "--start-step must be a number, got '${START_STEP}'"; }
# True when the given step number should run under the current --start-step.
step_enabled() { [[ "$1" -ge "${START_STEP}" ]]; }

# Default the smoke-test parameters to just the SRA accession if none were
# supplied. --test-parameter values, when given, fully replace this default.
if [[ ${#TEST_PARAMETERS[@]} -eq 0 ]]; then
  TEST_PARAMETERS=("SRA_accession_num=${TEST_SRA_ACCESSION}")
fi

# Resolve paths relative to this script so it works from anywhere
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ARGO_DIR="${REPO_ROOT}/cloud/argo"

# Files used from cloud/argo
NODEGROUP_TEMPLATE="${NODEGROUP_TEMPLATE:-${ARGO_DIR}/nodegroup_eks_template.yaml}"

###############################################################################
# 0. Pre-flight checks
###############################################################################
log "Pre-flight checks"

for cmd in aws curl tar gunzip jq; do
  command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
done

# Confirm AWS credentials are configured on this desktop.
aws sts get-caller-identity >/dev/null 2>&1 \
  || die "AWS credentials not configured. Run 'aws configure' (or refresh SSO) first."

[[ -f "${WORKFLOW_TEMPLATE}" ]] || die "Missing workflow template: ${WORKFLOW_TEMPLATE}"
[[ -f "${NODEGROUP_TEMPLATE}" ]] || die "Missing nodegroup template: ${NODEGROUP_TEMPLATE}"

# Detect OS for the binary downloads (darwin vs linux)
OS="linux"
if [[ "$(uname -s)" == "Darwin" ]]; then
  OS="darwin"
fi
ARCH="amd64"
if [[ "$(uname -m)" == "arm64" || "$(uname -m)" == "aarch64" ]]; then
  ARCH="arm64"
fi
log "Detected OS=${OS} ARCH=${ARCH}, region=${REGION}, cluster=${CLUSTER_NAME}"
log "Running steps numbered >= ${START_STEP}"

# Scratch dir used by several steps (CLI downloads, rendered policy/nodegroup,
# master-node user-data). Created unconditionally so steps still work when
# earlier steps are skipped via --start-step.
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

###############################################################################
# Step 1. Update eksctl, kubectl (and argo) on the local computer
###############################################################################
if step_enabled 1; then
log "Step 1: Updating local eksctl, kubectl and argo CLIs"

# --- kubectl ---
log "Installing/updating kubectl"
KUBECTL_STABLE="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
curl -fsSLo "${WORKDIR}/kubectl" \
  "https://dl.k8s.io/release/${KUBECTL_STABLE}/bin/${OS}/${ARCH}/kubectl"
chmod +x "${WORKDIR}/kubectl"
sudo mv "${WORKDIR}/kubectl" /usr/local/bin/kubectl
kubectl version --client

# --- eksctl ---
log "Installing/updating eksctl"
if [[ "${OS}" == "darwin" ]]; then
  PLATFORM="Darwin_${ARCH}"
else
  PLATFORM="Linux_${ARCH}"
fi
curl -fsSLo "${WORKDIR}/eksctl.tar.gz" \
  "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_${PLATFORM}.tar.gz"
curl -fsSL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_checksums.txt" \
  | grep "${PLATFORM}" | (cd "${WORKDIR}" && sha256sum --check)
tar -xzf "${WORKDIR}/eksctl.tar.gz" -C "${WORKDIR}"
sudo mv "${WORKDIR}/eksctl" /usr/local/bin/eksctl
eksctl version

# --- argo CLI (needed for `argo submit` from this desktop) ---
log "Installing/updating argo CLI"
curl -fsSLo "${WORKDIR}/argo.gz" \
  "https://github.com/argoproj/argo-workflows/releases/download/${ARGO_WORKFLOWS_VERSION}/argo-${OS}-${ARCH}.gz"
gunzip -f "${WORKDIR}/argo.gz"
chmod +x "${WORKDIR}/argo"
sudo mv "${WORKDIR}/argo" /usr/local/bin/argo
argo version
fi  # end Step 1

###############################################################################
# Step 2. Docker image (already pushed)
###############################################################################
if step_enabled 2; then
log "Step 2: Docker image (prerequisite, already pushed)"
echo "Using image: ${ECR_IMAGE}"
# Verify the image exists when it is a private ECR image (<account>.dkr.ecr.
# <region>.amazonaws.com/...) so we fail early if it is missing. Public ECR
# (public.ecr.aws/...) and other registries are not queried this way.
if [[ "${ECR_IMAGE}" =~ ^[0-9]+\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/ ]]; then
  ECR_REPO="$(echo "${ECR_IMAGE}" | sed -E 's#^[0-9]+\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/##; s/:.*$//')"
  ECR_TAG="$(echo "${ECR_IMAGE}" | sed -E 's/^.*://')"
  if ! aws ecr describe-images \
        --region "${REGION}" \
        --repository-name "${ECR_REPO}" \
        --image-ids imageTag="${ECR_TAG}" >/dev/null 2>&1; then
    warn "Could not verify image ${ECR_IMAGE} in ECR (check permissions/region). Continuing."
  else
    echo "Confirmed ${ECR_IMAGE} exists in ECR."
  fi
else
  echo "Image is not a private ECR URI; skipping ECR existence check."
fi
fi  # end Step 2

###############################################################################
# Step 3. EC2 master instance (created programmatically)
###############################################################################
# Previously a manual AWS-console step. Now provisioned with the AWS CLI: a
# ${MASTER_INSTANCE_TYPE} node (default t2.medium, ${MASTER_VOLUME_SIZE_GB} GB
# disk) with an admin instance profile, tagged Name=${MASTER_INSTANCE_NAME}. It
# bootstraps itself via user-data: clone the repo and run master_node_setup.sh.
# Idempotent: an existing non-terminated instance with that Name tag is reused.
if step_enabled 3; then
if [[ "${SKIP_MASTER_INSTANCE}" == "1" ]]; then
  warn "SKIP_MASTER_INSTANCE=1 set; skipping EC2 master instance creation (Step 3)."
else
  log "Step 3: Provisioning EC2 master instance ${MASTER_INSTANCE_NAME} (${MASTER_INSTANCE_TYPE})"

  # Reuse an existing (non-terminated) instance with the same Name tag.
  EXISTING_MASTER_ID="$(aws ec2 describe-instances --region "${REGION}" \
    --filters "Name=tag:Name,Values=${MASTER_INSTANCE_NAME}" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId | [0]' --output text 2>/dev/null || true)"

  if [[ -n "${EXISTING_MASTER_ID}" && "${EXISTING_MASTER_ID}" != "None" ]]; then
    warn "Master instance ${MASTER_INSTANCE_NAME} already exists (${EXISTING_MASTER_ID}); reusing it."
    MASTER_INSTANCE_ID="${EXISTING_MASTER_ID}"
  else
    # Key pair must already exist (we can't recreate the private key material).
    aws ec2 describe-key-pairs --region "${REGION}" --key-names "${MASTER_KEY_NAME}" >/dev/null 2>&1 \
      || die "EC2 key pair '${MASTER_KEY_NAME}' not found in ${REGION}. Create it (or pass --master-key-name), e.g. aws ec2 create-key-pair --key-name ${MASTER_KEY_NAME} --query KeyMaterial --output text > ~/.ssh/${MASTER_KEY_NAME}.pem"

    # Admin IAM role + instance profile (idempotent, each piece checked).
    log "Ensuring admin instance profile ${MASTER_ROLE_NAME}"
    if ! aws iam get-role --role-name "${MASTER_ROLE_NAME}" >/dev/null 2>&1; then
      aws iam create-role --role-name "${MASTER_ROLE_NAME}" \
        --assume-role-policy-document '{
          "Version": "2012-10-17",
          "Statement": [{
            "Effect": "Allow",
            "Principal": {"Service": "ec2.amazonaws.com"},
            "Action": "sts:AssumeRole"
          }]
        }' >/dev/null
    fi
    aws iam attach-role-policy --role-name "${MASTER_ROLE_NAME}" \
      --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
    if ! aws iam get-instance-profile --instance-profile-name "${MASTER_ROLE_NAME}" >/dev/null 2>&1; then
      aws iam create-instance-profile --instance-profile-name "${MASTER_ROLE_NAME}" >/dev/null
    fi
    # Add the role to the profile if it isn't already attached.
    if ! aws iam get-instance-profile --instance-profile-name "${MASTER_ROLE_NAME}" \
          --query 'InstanceProfile.Roles[].RoleName' --output text 2>/dev/null \
          | grep -qw "${MASTER_ROLE_NAME}"; then
      aws iam add-role-to-instance-profile \
        --instance-profile-name "${MASTER_ROLE_NAME}" --role-name "${MASTER_ROLE_NAME}"
      # Give IAM a moment to propagate before run-instances references the profile.
      sleep 10
    fi

    # Security group in the default VPC allowing inbound SSH from MASTER_SSH_CIDR.
    VPC_ID="$(aws ec2 describe-vpcs --region "${REGION}" \
      --filters Name=isDefault,Values=true \
      --query 'Vpcs[0].VpcId' --output text)"
    [[ -n "${VPC_ID}" && "${VPC_ID}" != "None" ]] \
      || die "No default VPC in ${REGION}; set MASTER_SECURITY_GROUP to an existing SG's setup or create a default VPC."
    SG_ID="$(aws ec2 describe-security-groups --region "${REGION}" \
      --filters "Name=group-name,Values=${MASTER_SECURITY_GROUP}" "Name=vpc-id,Values=${VPC_ID}" \
      --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
    if [[ -z "${SG_ID}" || "${SG_ID}" == "None" ]]; then
      log "Creating security group ${MASTER_SECURITY_GROUP} (SSH from ${MASTER_SSH_CIDR})"
      SG_ID="$(aws ec2 create-security-group --region "${REGION}" \
        --group-name "${MASTER_SECURITY_GROUP}" \
        --description "SSH access to the sandpiper master node" \
        --vpc-id "${VPC_ID}" --query 'GroupId' --output text)"
      aws ec2 authorize-security-group-ingress --region "${REGION}" \
        --group-id "${SG_ID}" --protocol tcp --port 22 --cidr "${MASTER_SSH_CIDR}" >/dev/null
    fi

    # Resolve the AMI (latest Ubuntu 22.04) unless one was provided.
    if [[ -z "${MASTER_AMI}" ]]; then
      log "Looking up latest Ubuntu 22.04 AMI in ${REGION}"
      MASTER_AMI="$(aws ssm get-parameter --region "${REGION}" \
        --name /aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
        --query 'Parameter.Value' --output text 2>/dev/null || true)"
      if [[ -z "${MASTER_AMI}" || "${MASTER_AMI}" == "None" ]]; then
        MASTER_AMI="$(aws ssm get-parameter --region "${REGION}" \
          --name /aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id \
          --query 'Parameter.Value' --output text)"
      fi
    fi
    [[ -n "${MASTER_AMI}" && "${MASTER_AMI}" != "None" ]] || die "Could not resolve an Ubuntu AMI; set MASTER_AMI explicitly."
    echo "Using AMI ${MASTER_AMI}"

    # User-data: clone the repo and run master_node_setup.sh as the ubuntu user,
    # so the node comes up fully provisioned without a manual SSH session.
    USERDATA="${WORKDIR}/master-userdata.sh"
    cat > "${USERDATA}" <<EOF
#!/bin/bash
exec > /var/log/sandpiper-master-setup.log 2>&1
set -x
apt-get update -y
apt-get install -y git
sudo -u ubuntu -H bash -c '
  cd /home/ubuntu
  git clone ${MASTER_REPO_URL} singlem-sra-processing || (cd singlem-sra-processing && git pull)
  cd /home/ubuntu/singlem-sra-processing/cloud/argo
  ./master_node_setup.sh
'
EOF

    log "Launching EC2 instance"
    MASTER_INSTANCE_ID="$(aws ec2 run-instances --region "${REGION}" \
      --image-id "${MASTER_AMI}" \
      --instance-type "${MASTER_INSTANCE_TYPE}" \
      --key-name "${MASTER_KEY_NAME}" \
      --iam-instance-profile "Name=${MASTER_ROLE_NAME}" \
      --security-group-ids "${SG_ID}" \
      --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=${MASTER_VOLUME_SIZE_GB},VolumeType=gp3}" \
      --user-data "file://${USERDATA}" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${MASTER_INSTANCE_NAME}}]" \
      --query 'Instances[0].InstanceId' --output text)"
    echo "Launched ${MASTER_INSTANCE_ID}; waiting for it to reach 'running'..."
    aws ec2 wait instance-running --region "${REGION}" --instance-ids "${MASTER_INSTANCE_ID}"
  fi

  MASTER_PUBLIC_DNS="$(aws ec2 describe-instances --region "${REGION}" \
    --instance-ids "${MASTER_INSTANCE_ID}" \
    --query 'Reservations[0].Instances[0].PublicDnsName' --output text)"
  cat <<EOF
Master instance ready: ${MASTER_INSTANCE_ID} (${MASTER_PUBLIC_DNS:-no public DNS})
  ssh -i ~/.ssh/${MASTER_KEY_NAME}.pem ubuntu@${MASTER_PUBLIC_DNS}
The node bootstraps via user-data (clone + master_node_setup.sh); follow it with:
  ssh ... 'tail -f /var/log/sandpiper-master-setup.log'
EOF
fi
fi  # end Step 3

###############################################################################
# Step 5. S3 bucket
###############################################################################
if step_enabled 5; then
log "Step 5: Ensuring S3 bucket ${BUCKET} exists in ${REGION}"
if aws s3api head-bucket --bucket "${BUCKET}" >/dev/null 2>&1; then
  echo "Bucket ${BUCKET} already exists."
else
  echo "Creating bucket ${BUCKET}..."
  if [[ "${REGION}" == "us-east-1" ]]; then
    # us-east-1 must NOT specify a LocationConstraint
    aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}"
  else
    aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}" \
      --create-bucket-configuration LocationConstraint="${REGION}"
  fi
fi
fi  # end Step 5

###############################################################################
# Step 6. Argo submission template (already present in repo)
###############################################################################
if step_enabled 6; then
log "Step 6: Using Argo workflow template ${WORKFLOW_TEMPLATE}"
fi  # end Step 6

###############################################################################
# Step 7. Create the EKS cluster and install Argo
###############################################################################
if step_enabled 7; then
if [[ "${SKIP_CLUSTER_CREATE:-0}" == "1" ]]; then
  warn "SKIP_CLUSTER_CREATE=1 set; skipping cluster creation."
else
  log "Step 7: Creating EKS cluster ${CLUSTER_NAME} (this takes ~15-20 min)"
  if eksctl get cluster --name "${CLUSTER_NAME}" --region "${REGION}" >/dev/null 2>&1; then
    warn "Cluster ${CLUSTER_NAME} already exists; skipping creation."
  else
    # The kubectl-version probe at the end of this command is known to fail
    # harmlessly; `set -e` would abort, so we tolerate it and fix the
    # kubeconfig ourselves in the next step.
    eksctl create cluster \
      --name="${CLUSTER_NAME}" \
      --region="${REGION}" \
      --nodes-min 0 --nodes-max 2 --nodes 0 \
      --spot --instance-types "${BOOTSTRAP_INSTANCE_TYPES}" \
      || warn "eksctl reported a non-zero exit (usually the kubectl version probe); continuing."
  fi
fi

log "Updating kubeconfig for ${CLUSTER_NAME}"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${REGION}"
kubectl version   # should now succeed against the cluster

log "Installing Argo Workflows ${ARGO_WORKFLOWS_VERSION} into namespace ${ARGO_NAMESPACE}"
kubectl get namespace "${ARGO_NAMESPACE}" >/dev/null 2>&1 \
  || kubectl create namespace "${ARGO_NAMESPACE}"
kubectl apply -n "${ARGO_NAMESPACE}" \
  -f "https://github.com/argoproj/argo-workflows/releases/download/${ARGO_WORKFLOWS_VERSION}/quick-start-minimal.yaml"

log "Waiting briefly for the Argo workflow-controller Deployment"
# NOTE: this cluster starts with 0 worker nodes and is scaled up MANUALLY
# (see Steps 11/14). The controller pod - like every workflow pod - needs a
# worker node, so it may stay Pending until you scale a nodegroup up. Don't
# abort the rest of the (node-independent) setup while waiting for capacity.
kubectl -n "${ARGO_NAMESPACE}" rollout status deploy/workflow-controller --timeout=120s \
  || warn "workflow-controller not Available yet - it needs worker capacity. Scale up a nodegroup (Steps 11/14) and it will start. Continuing setup."
fi  # end Step 7

# When resuming past cluster creation (--start-step > 7), Step 7 above did not
# run, so make sure this desktop's kubeconfig points at the cluster before the
# kubectl/argo steps below.
if ! step_enabled 7 && [[ "${START_STEP}" -le 11 ]]; then
  log "Ensuring kubeconfig for ${CLUSTER_NAME} (Step 7 skipped)"
  aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${REGION}"
fi

###############################################################################
# Step 8. Submit a test (hello-world) Argo job
###############################################################################
# Submitted without --watch: with 0 nodes the pod stays Pending until you scale
# up a nodegroup, and --watch would block the script indefinitely. The workflow
# is created now and the controller runs it once worker capacity exists.
if step_enabled 8; then
log "Step 8: Submitting hello-world test workflow (runs once worker capacity exists)"
argo submit -n "${ARGO_NAMESPACE}" \
  https://raw.githubusercontent.com/argoproj/argo-workflows/main/examples/hello-world.yaml
fi  # end Step 8

###############################################################################
# Step 9. Set up S3 permissions (IAM user + access key + k8s secret)
###############################################################################
if step_enabled 9; then
log "Step 9: Setting up S3 IAM user and Kubernetes credentials secret"

S3_USER="${BUCKET}-user"
S3_POLICY="${BUCKET}-policy"
ACCESS_KEY_FILE="${ARGO_DIR}/access-key-${REGION}.json"

# Create IAM user (idempotent)
if aws iam get-user --user-name "${S3_USER}" >/dev/null 2>&1; then
  echo "IAM user ${S3_USER} already exists."
else
  aws iam create-user --user-name "${S3_USER}"
fi

# Render the S3 access policy for the selected bucket. The static
# cloud/argo/policy.json is hard-coded to the default bucket, so generate the
# document from ${BUCKET} here to keep the credentials valid when --bucket is
# overridden.
RENDERED_POLICY="${WORKDIR}/policy.json"
jq -n --arg bucket "${BUCKET}" '{
  Version: "2012-10-17",
  Statement: [
    {
      Effect: "Allow",
      Action: ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
      Resource: "arn:aws:s3:::\($bucket)/*"
    },
    {
      Effect: "Allow",
      Action: ["s3:ListBucket"],
      Resource: "arn:aws:s3:::\($bucket)"
    }
  ]
}' > "${RENDERED_POLICY}"

# Attach inline policy (idempotent - put-user-policy overwrites)
aws iam put-user-policy \
  --user-name "${S3_USER}" \
  --policy-name "${S3_POLICY}" \
  --policy-document "file://${RENDERED_POLICY}"

# Create an access key only if the k8s secret does not already exist.
if kubectl -n "${ARGO_NAMESPACE}" get secret "${S3_SECRET_NAME}" >/dev/null 2>&1; then
  warn "Secret ${S3_SECRET_NAME} already exists in namespace ${ARGO_NAMESPACE}; not creating a new access key."
else
  log "Creating a new IAM access key and Kubernetes secret ${S3_SECRET_NAME}"
  aws iam create-access-key --user-name "${S3_USER}" > "${ACCESS_KEY_FILE}"
  chmod 600 "${ACCESS_KEY_FILE}"

  ACCESS_KEY_ID="$(jq -r '.AccessKey.AccessKeyId' "${ACCESS_KEY_FILE}")"
  SECRET_ACCESS_KEY="$(jq -r '.AccessKey.SecretAccessKey' "${ACCESS_KEY_FILE}")"
  [[ -n "${ACCESS_KEY_ID}" && "${ACCESS_KEY_ID}" != "null" ]] \
    || die "Failed to read access key from ${ACCESS_KEY_FILE}"

  kubectl create secret generic "${S3_SECRET_NAME}" \
    --from-literal=accessKey="${ACCESS_KEY_ID}" \
    --from-literal=secretKey="${SECRET_ACCESS_KEY}" \
    --namespace "${ARGO_NAMESPACE}"
  echo "Stored access key in ${ACCESS_KEY_FILE} (keep this safe / out of git)."
fi
fi  # end Step 9

###############################################################################
# Step 10. Submit a real job using the workflow template
###############################################################################
# Submitted without --watch for the same reason as Step 8: the job stays
# Pending until a nodegroup is scaled up, and --watch would block indefinitely.
if step_enabled 10; then
log "Step 10: Submitting test job with the workflow template (runs once worker capacity exists)"
echo "Parameters: ${TEST_PARAMETERS[*]}"
PARAM_ARGS=()
for p in "${TEST_PARAMETERS[@]}"; do
  PARAM_ARGS+=(--parameter "${p}")
done
argo submit -n "${ARGO_NAMESPACE}" \
  "${PARAM_ARGS[@]}" \
  "${WORKFLOW_TEMPLATE}"
fi  # end Step 10

###############################################################################
# Step 11. Scale-up setup: IO-optimised nodegroup + controller parallelism
###############################################################################
if step_enabled 11; then
log "Step 11a: Replacing the bootstrap nodegroup with an IO-optimised one"

# Delete any nodegroups eksctl auto-provisioned at cluster creation so that
# only the IO-optimised nodegroup remains. The IO nodegroup itself
# (${IO_NODEGROUP_NAME}) is explicitly preserved so that re-runs (e.g. with
# SKIP_CLUSTER_CREATE=1) do not drain/evict active workflows or tear down
# production capacity created on a previous run.
log "Deleting bootstrap nodegroup(s) created during cluster launch"
EXISTING_NGS="$(eksctl get nodegroup --cluster "${CLUSTER_NAME}" --region "${REGION}" -o json \
  | jq -r '.[].Name' || true)"
if [[ -n "${EXISTING_NGS}" ]]; then
  while IFS= read -r ng; do
    [[ -z "${ng}" ]] && continue
    if [[ "${ng}" == "${IO_NODEGROUP_NAME}" ]]; then
      echo "Keeping existing IO nodegroup ${ng} (not deleting)."
      continue
    fi
    echo "Deleting bootstrap nodegroup ${ng}..."
    eksctl delete nodegroup \
      --cluster "${CLUSTER_NAME}" --region "${REGION}" \
      --name "${ng}" --wait
  done <<< "${EXISTING_NGS}"
else
  echo "No existing nodegroups found to delete."
fi

# If the IO nodegroup already exists (a re-run), skip re-creating it.
if echo "${EXISTING_NGS}" | grep -qx "${IO_NODEGROUP_NAME}"; then
  warn "IO nodegroup ${IO_NODEGROUP_NAME} already exists; skipping creation."
  IO_NODEGROUP_EXISTS=1
else
  IO_NODEGROUP_EXISTS=0
fi

if [[ "${IO_NODEGROUP_EXISTS}" == "1" ]]; then
  echo "Reusing existing IO nodegroup ${IO_NODEGROUP_NAME}."
else
  log "Creating IO-optimised nodegroup ${IO_NODEGROUP_NAME} from ${NODEGROUP_TEMPLATE}"
  # Patch the template on the fly so it works against this cluster without
  # manual edits: metadata.name/region match ${CLUSTER_NAME}/${REGION}, and the
  # first managedNodeGroups name is set to ${IO_NODEGROUP_NAME} so the created
  # nodegroup matches the scale command printed at the end of this script.
  PATCHED_NODEGROUP="${WORKDIR}/nodegroup.yaml"
  cat > "${PATCHED_NODEGROUP}" <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${CLUSTER_NAME}
  region: ${REGION}

EOF
  # Keep the managedNodeGroups section from the template, but rename the first
  # nodegroup to ${IO_NODEGROUP_NAME} (only the first "- name:" is replaced).
  sed -n '/^managedNodeGroups:/,$p' "${NODEGROUP_TEMPLATE}" \
    | sed -E "0,/^([[:space:]]*- name:[[:space:]]*).*/s//\1${IO_NODEGROUP_NAME}/" \
    >> "${PATCHED_NODEGROUP}"
  eksctl create nodegroup -f "${PATCHED_NODEGROUP}"
fi

log "Step 11b: Raising Argo controller parallelism and retention"
# Non-interactive equivalent of:
#   KUBE_EDITOR=micro kubectl edit configmap workflow-controller-configmap -n argo
RETENTION_YAML="completed: ${RETENTION_COMPLETED}
failed: ${RETENTION_FAILED}
errored: ${RETENTION_ERRORED}
"
kubectl patch configmap workflow-controller-configmap \
  -n "${ARGO_NAMESPACE}" --type merge \
  -p "$(jq -n \
        --arg par "${NAMESPACE_PARALLELISM}" \
        --arg ret "${RETENTION_YAML}" \
        '{data: {namespaceParallelism: $par, retentionPolicy: $ret}}')"

log "Restarting the Argo workflow-controller to pick up the new config"
kubectl -n "${ARGO_NAMESPACE}" rollout restart deploy/workflow-controller
# Non-fatal: like the initial rollout, this only completes once worker capacity
# exists (this cluster is scaled up manually - see Steps 11/14).
kubectl -n "${ARGO_NAMESPACE}" rollout status deploy/workflow-controller --timeout=120s \
  || warn "workflow-controller restart not Available yet - scale up a nodegroup (Step 14) to provide capacity."
fi  # end Step 11

###############################################################################
# Steps 12-14. Production submission, monitoring and scaling (informational)
###############################################################################
# Tailor the bulk-submission hint to the chosen workflow template. The weebill
# template is driven by slow_argo_submission_weebill.py (CSV input + a shared
# reference .sylref URI); other templates use slow_argo_submission.py.
if [[ "$(basename "${WORKFLOW_TEMPLATE}")" == *weebill* ]]; then
  BULK_SUBMISSION_HELP="./slow_argo_submission_weebill.py \\
        --input-runlist-csv <pods.csv> \\
        --workflow-template ${WORKFLOW_TEMPLATE} \\
        --reference-s3-uri s3://${BUCKET}/references/weebill/gtdb.sylref \\
        --min-running-pending-file min_job_count \\
        --batch-size-file batch_size
      (build <pods.csv> with sra_weebill_batch_creation.ipynb; columns
       pod_accessions, batch_name, ephemeral_storage_mb)"
else
  BULK_SUBMISSION_HELP="./slow_argo_submission.py \\
        --input-runlist <runlist.txt> \\
        --workflow-template ${WORKFLOW_TEMPLATE} \\
        --min-running-pending-file min_job_count \\
        --batch-size-file batch_size"
fi

log "Setup complete. Next steps (run manually as needed):"
cat <<EOF

IMPORTANT: this cluster has 0 worker nodes right now. The Argo controller and
the two test workflows just submitted (Steps 8 & 10) stay Pending until you
scale a nodegroup up. Do that first (Step 14 below), then watch them, e.g.:
      argo list -n ${ARGO_NAMESPACE}
      argo get  -n ${ARGO_NAMESPACE} @latest

12. Bulk submission (slow, rate-limited) from ${ARGO_DIR}:
      ${BULK_SUBMISSION_HELP}

13. Monitoring:
      k9s
      kubectl get pods --all-namespaces --no-headers \\
        | awk '{print \$4}' | sort | uniq -c

14. Scale the IO nodegroup up/down as throughput allows:
      eksctl scale nodegroup \\
        --cluster ${CLUSTER_NAME} \\
        --name ${IO_NODEGROUP_NAME} \\
        --region ${REGION} \\
        --nodes 5 --nodes-min 0 --nodes-max ${IO_NODEGROUP_MAX}

To tear the cluster down when finished:
      eksctl delete cluster --name ${CLUSTER_NAME} --region ${REGION}
EOF

log "Done."
