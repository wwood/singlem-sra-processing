#!/bin/bash -e



sudo apt install jq -y

##### ARGO

# Detect OS
ARGO_OS="darwin"
if [[ $(uname -s) != "Darwin" ]]; then
  ARGO_OS="linux"
fi

# Download the binary
ARGO_VERSION=$(curl -fsSL \
  https://api.github.com/repos/argoproj/argo-workflows/releases/latest \
  | jq -r .tag_name)
curl -sLO "https://github.com/argoproj/argo-workflows/releases/download/$ARGO_VERSION/argo-$ARGO_OS-amd64.gz"

# Unzip
gunzip "argo-$ARGO_OS-amd64.gz"

# Make binary executable
chmod +x "argo-$ARGO_OS-amd64"

# Move binary to path
sudo mv "./argo-$ARGO_OS-amd64" /usr/local/bin/argo

# Test installation
argo version


##### AWS cli
sudo apt install unzip

curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
aws --version
rm awscliv2.zip


##### Kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/kubectl
kubectl version --client



##### eksctl
# for ARM systems, set ARCH to: `arm64`, `armv6` or `armv7`
ARCH=amd64
PLATFORM=$(uname -s)_$ARCH

curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$PLATFORM.tar.gz"

# (Optional) Verify checksum
curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_checksums.txt" | grep $PLATFORM | sha256sum --check

tar -xzf eksctl_$PLATFORM.tar.gz -C /tmp && rm eksctl_$PLATFORM.tar.gz

sudo mv /tmp/eksctl /usr/local/bin
eksctl version


#### k9s
curl -sS https://webinstall.dev/k9s | bash
source ~/.config/envman/PATH.env
k9s version


#### saml2aws - needed? Is out of date at least, config needs updating
CURRENT_VERSION=2.36.18
wget https://github.com/Versent/saml2aws/releases/download/v${CURRENT_VERSION}/saml2aws_${CURRENT_VERSION}_linux_amd64.tar.gz
tar -xzvf saml2aws_${CURRENT_VERSION}_linux_amd64.tar.gz
sudo mv saml2aws /usr/local/bin/
sudo chmod ugo+x /usr/local/bin//saml2aws
saml2aws --version
rm saml2aws_${CURRENT_VERSION}_linux_amd64.tar.gz

# config
cat <<EOF > ~/.saml2aws
[default]
app_id               =
url                  = https://idp.qut.edu.au/idp/profile/SAML2/Unsolicited/SSO?providerId=urn:amazon:webservices
username             = woodcrob
provider             = KeyCloak
mfa                  = Auto
skip_verify          = false
timeout              = 0
aws_urn              = urn:amazon:webservices
aws_session_duration = 3600
aws_profile          = default
resource_id          =
subdomain            =
role_arn             =
http_attempts_count  =
http_retry_delay     =
region               = us-east-1
EOF

sudo apt install xvfb -y
# xvfb-run saml2aws login --session-duration=28800



#### pip and extern for slow_submit
sudo apt update
sudo apt install -y python3-pip
# sudo pip3 install extern
pip install extern --break-system-packages



sudo apt install parallel -y

curl -fsSL https://pixi.sh/install.sh | sh
