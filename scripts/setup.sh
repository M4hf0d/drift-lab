#!/usr/bin/env bash
# One-time environment setup:
#   1. create a kind cluster
#   2. build the app image and load it into kind (no registry needed)
#   3. install Argo CD (stable manifests) into the argocd namespace
#   4. create the two app namespaces + the out-of-git Secret in each
#   5. print the admin password and the port-forward command
#
# This does NOT apply the Argo Application manifests in argocd/ --
# do that after you've pushed this repo to GitHub and edited the
# repoURL placeholder in argocd/selfheal-off.yaml and selfheal-on.yaml.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

echo "== 1/5: creating kind cluster '${CLUSTER_NAME}' =="
if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  echo "cluster ${CLUSTER_NAME} already exists, skipping create"
else
  kind create cluster --name "${CLUSTER_NAME}"
fi

echo "== 2/5: building and loading app image =="
docker build -t "${IMAGE_NAME}" ./app
kind load docker-image "${IMAGE_NAME}" --name "${CLUSTER_NAME}"

echo "== 3/5: installing Argo CD =="
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
# --server-side: the plain client-side `kubectl apply` keeps a full copy of
# the previous manifest in a kubectl.kubernetes.io/last-applied-configuration
# annotation, and the ApplicationSet CRD in this install manifest is large
# enough to blow past etcd's 256KiB annotation-size limit, which fails apply
# with "metadata.annotations: Too long". Server-side apply tracks field
# ownership instead of stashing a full copy, so it doesn't hit that limit.
kubectl apply --server-side --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
echo "waiting for argocd-server to be available (this can take a few minutes)..."
kubectl -n argocd wait --for=condition=available --timeout=300s deployment/argocd-server
kubectl -n argocd wait --for=condition=available --timeout=300s deployment/argocd-repo-server
kubectl -n argocd wait --for=condition=available --timeout=300s deployment/argocd-applicationset-controller

echo "== 4/5: creating app namespaces + out-of-git Secret =="
for variant in off on; do
  ns="$(variant_to_ns "${variant}")"
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "${ns}" create secret generic driftapp-secret \
    --from-literal=value="${SECRET_VALUE}" \
    --dry-run=client -o yaml | kubectl apply -f -
done

echo "== 5/5: admin credentials =="
ADMIN_PW="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
echo "argocd admin password: ${ADMIN_PW}"
echo
echo "Next steps:"
echo "  1. Push this repo to GitHub."
echo "  2. Edit argocd/selfheal-off.yaml and selfheal-on.yaml: set repoURL."
echo "  3. kubectl apply -f argocd/selfheal-off.yaml -f argocd/selfheal-on.yaml"
echo "  4. In another terminal: kubectl -n argocd port-forward svc/argocd-server 8080:443"
echo "  5. argocd login localhost:8080 --username admin --password '<pw above>' --insecure"
