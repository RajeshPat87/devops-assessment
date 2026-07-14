#!/usr/bin/env bash
# Shared kubectl shorthands. Source this, do not execute it:
#
#   source scripts/kubectl-aliases.sh
#
# To load them in every shell, add that line to your ~/.bashrc.

# Aliases set here vanish when a subshell exits, so running this file as a
# program is a no-op. Catch that instead of failing silently.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "kubectl-aliases.sh must be sourced, not executed:" >&2
  echo "  source ${BASH_SOURCE[0]}" >&2
  exit 1
fi

# --- Core ---
alias k='kubectl'
alias kga='kubectl get all'
alias kgns='kubectl get namespaces'
alias kgn='kubectl get nodes'

# --- Pod management & troubleshooting ---
alias kgp='kubectl get pods'
alias kgpw='kubectl get pods -o wide'
alias kgp-watch='kubectl get pods -w'   # Crucial for monitoring startup probes
alias kdp='kubectl describe pod'
alias kl='kubectl logs'
alias klf='kubectl logs -f'             # Follow logs
alias kexec='kubectl exec -it'          # Interactive shell into container
alias krmp='kubectl delete pod'
alias kge='kubectl get events --sort-by=.lastTimestamp'

# --- Deployments & scaling ---
alias kgd='kubectl get deployments'
alias kdd='kubectl describe deployment'
alias ked='kubectl edit deployment'
alias kscale='kubectl scale deployment'
alias krr='kubectl rollout restart deployment' # Forces a fresh boot/probe test
alias krmd='kubectl delete deployment'

# --- Services, ingress & config ---
alias kgs='kubectl get svc'
alias kds='kubectl describe service'
alias kgi='kubectl get ingress'
alias kgcm='kubectl get configmap'
alias kdcm='kubectl describe configmap'
alias kgsec='kubectl get secret'

# --- Execution & context ---
alias kaf='kubectl apply -f'
alias kdf='kubectl delete -f'
alias kctx='kubectl config use-context'
alias kns='kubectl config set-context --current --namespace'

# --- Combined utility ---
# First stop when a pod is stuck in CrashLoopBackOff:
alias k-debug='kubectl get pod -o wide && echo "---" && kubectl get events --sort-by=.lastTimestamp | tail -n 10'

# --- RBAC: get ---
alias kgr='kubectl get roles'
alias kgrb='kubectl get rolebindings'
alias kgcr='kubectl get clusterroles'
alias kgcrb='kubectl get clusterrolebindings'
alias kgsa='kubectl get serviceaccounts'
alias kgra='kubectl get roles -A'
alias kgrba='kubectl get rolebindings -A'

# --- RBAC: describe ---
alias kdr='kubectl describe role'
alias kdrb='kubectl describe rolebinding'
alias kdcr='kubectl describe clusterrole'
alias kdcrb='kubectl describe clusterrolebinding'
alias kdsa='kubectl describe serviceaccount'
alias kcan='kubectl auth can-i'
