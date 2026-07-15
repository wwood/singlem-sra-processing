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
# A handful of steps in the original manual runbook were done via the AWS
# console (creating the EC2 master instance, pushing the docker image, and
# creating the S3 bucket). Those are checked for / created here where it is
# safe to automate, and otherwise reported as prerequisites.
#
# Usage:
#   ./setup_weebill.bash                 # run the full setup
#   SKIP_CLUSTER_CREATE=1 ./setup_weebill.bash   # skip long-running steps, e.g. re-runs
#
set -euo pipefail

###############################################################################
# Configuration (override any of these via the environment)
###############################################################################
REGION="${REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-sandpiper}"
BUCKET="${BUCKET:-woodcrob-sandpiper-us-east-1}"
ECR_IMAGE="${ECR_IMAGE:-656626576102.dkr.ecr.us-east-1.amazonaws.com/singlem/sracat_weebill:v3}"

# Cluster bootstrap node settings (the initial throwaway nodegroup)
BOOTSTRAP_INSTANCE_TYPES="${BOOTSTRAP_INSTANCE_TYPES:-c7a.12xlarge}"

# Argo settings
ARGO_WORKFLOWS_VERSION="${ARGO_WORKFLOWS_VERSION:-v3.7.6}"
ARGO_NAMESPACE="${ARGO_NAMESPACE:-argo}"

# Kubernetes secret holding the S3 credentials that jobs use
S3_SECRET_NAME="${S3_SECRET_NAME:-my-s3-credentials}"

# Argo controller scaling
NAMESPACE_PARALLELISM="${NAMESPACE_PARALLELISM:-3000}"
RETENTION_COMPLETED="${RETENTION_COMPLETED:-500}"
RETENTION_FAILED="${RETENTION_FAILED:-500}"
RETENTION_ERRORED="${RETENTION_ERRORED:-500}"

# Production IO-optimised nodegroup (created for scale-up)
IO_NODEGROUP_NAME="${IO_NODEGROUP_NAME:-io-logan-mach2}"
IO_NODEGROUP_MAX="${IO_NODEGROUP_MAX:-100}"

# A test accession to submit through the real template
TEST_SRA_ACCESSION="${TEST_SRA_ACCESSION:-SRR8653040}"

# Resolve paths relative to this script so it works from anywhere
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ARGO_DIR="${REPO_ROOT}/cloud/argo"

# Files used from cloud/argo
WORKFLOW_TEMPLATE="${ARGO_DIR}/logan_workflow_template.yaml"
POLICY_FILE="${ARGO_DIR}/policy.json"
NODEGROUP_TEMPLATE="${NODEGROUP_TEMPLATE:-${ARGO_DIR}/nodegroup_eks_template.yaml}"

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

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
[[ -f "${POLICY_FILE}" ]]       || die "Missing IAM policy file: ${POLICY_FILE}"
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

###############################################################################
# Step 1. Update eksctl, kubectl (and argo) on the local computer
###############################################################################
log "Step 1: Updating local eksctl, kubectl and argo CLIs"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

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

###############################################################################
# Step 2. Docker image (already pushed)
###############################################################################
log "Step 2: Docker image (prerequisite, already pushed)"
echo "Using image: ${ECR_IMAGE}"
# Verify the image exists in ECR so we fail early if it is missing.
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

###############################################################################
# Step 3. EC2 master instance (prerequisite)
###############################################################################
log "Step 3: EC2 master instance (prerequisite, created via the console)"
cat <<'EOF'
This step is done manually via the AWS console:
  - Instance:   sandpiper-master2 (admin/instance profile), t2.medium, 20 GB disk
  - Login:      ssh -i ~/.ssh/woodcrob1.pem ubuntu@<master-public-dns>
  - On master:  git clone https://github.com/wwood/singlem-sra-processing/
                cd singlem-sra-processing/cloud/argo
                ./master_node_setup.sh
This script instead drives the cluster from this desktop, so the master node
is optional. Skipping.
EOF

###############################################################################
# Step 5. S3 bucket
###############################################################################
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

###############################################################################
# Step 6. Argo submission template (already present in repo)
###############################################################################
log "Step 6: Using Argo workflow template ${WORKFLOW_TEMPLATE}"

###############################################################################
# Step 7. Create the EKS cluster and install Argo
###############################################################################
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

log "Waiting for the Argo workflow-controller to become available"
kubectl -n "${ARGO_NAMESPACE}" rollout status deploy/workflow-controller --timeout=300s

###############################################################################
# Step 8. Submit a test (hello-world) Argo job
###############################################################################
log "Step 8: Submitting hello-world test workflow"
argo submit -n "${ARGO_NAMESPACE}" --watch \
  https://raw.githubusercontent.com/argoproj/argo-workflows/main/examples/hello-world.yaml

###############################################################################
# Step 9. Set up S3 permissions (IAM user + access key + k8s secret)
###############################################################################
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

# Attach inline policy (idempotent - put-user-policy overwrites)
aws iam put-user-policy \
  --user-name "${S3_USER}" \
  --policy-name "${S3_POLICY}" \
  --policy-document "file://${POLICY_FILE}"

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

###############################################################################
# Step 10. Submit a real job using the workflow template
###############################################################################
log "Step 10: Submitting test job with the workflow template (accession ${TEST_SRA_ACCESSION})"
argo submit -n "${ARGO_NAMESPACE}" \
  --parameter SRA_accession_num="${TEST_SRA_ACCESSION}" \
  "${WORKFLOW_TEMPLATE}" --watch

###############################################################################
# Step 11. Scale-up setup: IO-optimised nodegroup + controller parallelism
###############################################################################
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
kubectl -n "${ARGO_NAMESPACE}" rollout status  deploy/workflow-controller --timeout=300s

###############################################################################
# Steps 12-14. Production submission, monitoring and scaling (informational)
###############################################################################
log "Setup complete. Next steps (run manually as needed):"
cat <<EOF

12. Bulk submission (slow, rate-limited) from ${ARGO_DIR}:
      ./slow_argo_submission.py \\
        --input-runlist <runlist.txt> \\
        --workflow-template ${WORKFLOW_TEMPLATE} \\
        --min-running-pending-file min_job_count \\
        --batch-size-file batch_size

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
