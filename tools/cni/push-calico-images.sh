#!/usr/bin/env bash
set -euo pipefail

CALICO_DIR="templates/manifests/cni/calico"
DEFAULT_SOURCE_REGISTRY="quay.io"

# Linux images: calico/*
CALICO_LINUX_IMAGES=(
    "calico/node"
    "calico/cni"
    "calico/apiserver"
    "calico/kube-controllers"
    "calico/envoy-gateway"
    "calico/envoy-proxy"
    "calico/envoy-ratelimit"
    "calico/dikastes"
    "calico/pod2daemon-flexvol"
    "calico/key-cert-provisioner"
    "calico/goldmane"
    "calico/whisker"
    "calico/whisker-backend"
)

usage() {
    echo "Usage: $0 <calico-version> <target-registry> [options]"
    echo ""
    echo "  calico-version    Calico release version (e.g. v3.31.5)"
    echo "  target-registry   Destination registry (e.g. harbor.company.local/calico)"
    echo ""
    echo "Options:"
    echo "  --dry-run         Print images without pushing"
    echo "  --source-registry Override source registry (default: quay.io)"
    echo ""
    echo "Examples:"
    echo "  $0 v3.31.5 harbor.company.local/calico"
    echo "  $0 v3.31.5 harbor.company.local/calico --dry-run"
    echo "  $0 v3.31.5 harbor.company.local/calico --source-registry my-mirror.local"
    echo ""
    echo "Image list based on:"
    echo "  https://docs.tigera.io/calico/latest/operations/image-options/alternate-registry"
}

if [[ $# -lt 2 ]]; then
    usage
    exit 1
fi

CALICO_VERSION="${1}"
TARGET_REGISTRY="${2}"
shift 2

DRY_RUN=false
SOURCE_REGISTRY="${DEFAULT_SOURCE_REGISTRY}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)        DRY_RUN=true; shift ;;
        --source-registry) SOURCE_REGISTRY="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# Extract operator image tag from the deployment manifest
DEPLOYMENT_J2="${CALICO_DIR}/${CALICO_VERSION}/manifests/tigera-operator/templates/tigera-operator/02-tigera-operator.yaml.j2"

if [[ -f "${DEPLOYMENT_J2}" ]]; then
    OPERATOR_TAG=$(sed -n 's|.*tigera/operator:\(.*\)|\1|p' "${DEPLOYMENT_J2}" | head -1)
else
    echo "ERROR: Deployment manifest not found at ${DEPLOYMENT_J2}"
    echo "Run build-calico.sh ${CALICO_VERSION} first."
    exit 1
fi

if [[ -z "${OPERATOR_TAG}" ]]; then
    echo "ERROR: Could not extract operator image tag from ${DEPLOYMENT_J2}"
    exit 1
fi

echo "==> Calico version:    ${CALICO_VERSION}"
echo "==> Operator tag:      ${OPERATOR_TAG}"
echo "==> Source registry:   ${SOURCE_REGISTRY}"
echo "==> Target registry:   ${TARGET_REGISTRY}"
echo ""

retag_push() {
    local source_image="${1}"
    local target_image="${2}"

    echo "    ${source_image} -> ${target_image}"

    if [[ "${DRY_RUN}" == true ]]; then
        return
    fi

    docker pull "${source_image}"
    docker tag "${source_image}" "${target_image}"
    docker push "${target_image}"
}

echo "==> Operator image:"
retag_push \
    "${SOURCE_REGISTRY}/tigera/operator:${OPERATOR_TAG}" \
    "${TARGET_REGISTRY}/tigera/operator:${OPERATOR_TAG}"

echo ""
echo "==> Calico images (${#CALICO_LINUX_IMAGES[@]}):"
for image in "${CALICO_LINUX_IMAGES[@]}"; do
    retag_push \
        "${SOURCE_REGISTRY}/${image}:${CALICO_VERSION}" \
        "${TARGET_REGISTRY}/${image}:${CALICO_VERSION}"
done

echo ""
if [[ "${DRY_RUN}" == true ]]; then
    echo "==> Dry run complete. Total images: $(( ${#CALICO_LINUX_IMAGES[@]} + 1 ))"
else
    echo "==> Done! Total images pushed: $(( ${#CALICO_LINUX_IMAGES[@]} + 1 ))"
fi
