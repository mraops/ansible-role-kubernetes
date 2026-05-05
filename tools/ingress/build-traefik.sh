#!/usr/bin/env bash
set -euo pipefail

TRAEFIK_DIR="templates/manifests/ingress/traefik"
HELM_REPO="https://traefik.github.io/charts"
NAMESPACE="traefik"

usage() {
    echo "Usage: $0 <chart-version> [--clean]"
    echo ""
    echo "  chart-version   Traefik Helm chart version (e.g. v34.2.0)"
    echo "  --clean         Remove existing version directory before generating"
    echo ""
    echo "Examples:"
    echo "  $0 v34.2.0          Generate manifests for v34.2.0"
    echo "  $0 v35.0.0 --clean  Regenerate v35.0.0 from scratch"
    echo ""
    echo "After running, update defaults/main.yml:"
    echo "  kubernetes_extensions_traefik_chart_version: \"<version>\""
}

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

VERSION="${1}"
CLEAN=false

if [[ "${2:-}" == "--clean" ]]; then
    CLEAN=true
fi

VERSION_DIR="${TRAEFIK_DIR}/${VERSION}"
MANIFESTS_DIR="${VERSION_DIR}/manifests/traefik/templates"
CRDS_DIR="${VERSION_DIR}/crds"

echo "==> Traefik chart version: ${VERSION}"

if [[ "${CLEAN}" == true ]] && [[ -d "${VERSION_DIR}" ]]; then
    echo "==> Removing existing ${VERSION_DIR}..."
    rm -rf "${VERSION_DIR}"
fi

mkdir -p "${VERSION_DIR}"

# values.yaml
if [[ -f "${VERSION_DIR}/values.yaml" ]]; then
    echo "==> Using existing values.yaml"
else
    echo "==> Creating default values.yaml"
    cat > "${VERSION_DIR}/values.yaml" << 'EOF'
deployment:
  kind: Deployment

service:
  type: NodePort
  externalTrafficPolicy: Local

ports:
  web:
    port: 8000
    exposedPort: 80
    nodePort: 30080
    expose:
      default: true
  websecure:
    port: 8443
    exposedPort: 443
    nodePort: 30443
    expose:
      default: true
    tls:
      enabled: true

ingressRoute:
  dashboard:
    enabled: false

metrics:
  prometheus:
    enabled: false
EOF
fi

# Helm repo
echo "==> Updating Helm repo..."
helm repo add traefik "${HELM_REPO}" 2>/dev/null || true
helm repo update traefik

# Generate manifests
echo "==> Generating manifests..."
cd "${VERSION_DIR}"
helm template traefik traefik/traefik \
    --version "${VERSION}" \
    -f values.yaml \
    --namespace "${NAMESPACE}" \
    --output-dir manifests
cd - > /dev/null

# Extract CRDs
echo "==> Extracting CRDs..."
mkdir -p "${CRDS_DIR}"
helm show crds traefik/traefik --version "${VERSION}" > "${CRDS_DIR}/crds.yaml"

# Create namespace manifest
echo "==> Creating namespace manifest..."
mkdir -p "${MANIFESTS_DIR}"
cat > "${MANIFESTS_DIR}/00-namespace-traefik.yaml" << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: traefik
  labels:
    app.kubernetes.io/name: traefik
EOF

# Jinja2 replacements
DEPLOYMENT_SRC="${MANIFESTS_DIR}/deployment.yaml"
SERVICE_SRC="${MANIFESTS_DIR}/service.yaml"

if [[ -f "${DEPLOYMENT_SRC}" ]]; then
    echo "==> Injecting Jinja2 into deployment..."
    IMAGE_TAG=$(sed -n 's|.*image: docker.io/traefik:\(.*\)|\1|p' "${DEPLOYMENT_SRC}" | head -1)
    sed -i '' 's|image: docker.io|image: {{ kubernetes_extensions_traefik_image_repo }}|' "${DEPLOYMENT_SRC}"
    mv "${DEPLOYMENT_SRC}" "${DEPLOYMENT_SRC}.j2"
    echo "    Image tag: ${IMAGE_TAG}"
else
    echo "WARNING: deployment.yaml not found at ${DEPLOYMENT_SRC}"
fi

if [[ -f "${SERVICE_SRC}" ]]; then
    echo "==> Injecting Jinja2 into service..."
    sed -i '' 's|nodePort: 30080|nodePort: {{ kubernetes_extensions_traefik_http_node_port }}|' "${SERVICE_SRC}"
    sed -i '' 's|nodePort: 30443|nodePort: {{ kubernetes_extensions_traefik_https_node_port }}|' "${SERVICE_SRC}"
    mv "${SERVICE_SRC}" "${SERVICE_SRC}.j2"
else
    echo "WARNING: service.yaml not found at ${SERVICE_SRC}"
fi

echo ""
echo "==> Done! Files in ${VERSION_DIR}/:"
find "${VERSION_DIR}" -type f | sort | sed "s|${VERSION_DIR}/||"
echo ""
echo "==> Update defaults/main.yml:"
echo "    kubernetes_extensions_traefik_chart_version: \"${VERSION}\""
