#!/usr/bin/env bash
# kind-setup.sh — Setup completo do cluster local para checklist-compras
# Uso: bash scripts/kind-setup.sh
# Requer: kind, kubectl, helm, docker

set -euo pipefail

CLUSTER_NAME="compras"
NAMESPACE="comprasweb-local"
IMAGE_NAME="comprasweb-local:latest"

echo "=== checklist-compras kind setup ==="

# ── 1. Cluster ────────────────────────────────────────────────────────
echo "[1/7] Criando cluster kind '$CLUSTER_NAME'..."
if kind get clusters | grep -q "^$CLUSTER_NAME$"; then
  echo "  Cluster já existe, pulando."
else
  kind create cluster --config kind-config.yaml
fi

# ── 2. Ingress nginx ──────────────────────────────────────────────────
echo "[2/7] Instalando nginx ingress controller..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=90s

# ── 3. Metrics server ─────────────────────────────────────────────────
echo "[3/7] Instalando metrics-server (com --kubelet-insecure-tls para kind)..."
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl patch deployment metrics-server -n kube-system \
  --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl rollout status deployment/metrics-server -n kube-system --timeout=90s

# ── 4. Imagens ────────────────────────────────────────────────────────
echo "[4/7] Buildando e carregando imagens..."
docker build -t "$IMAGE_NAME" .
kind load docker-image "$IMAGE_NAME" --name "$CLUSTER_NAME"
# Versões pinadas e multi-arch (ARM64 + AMD64)
kind load docker-image postgres:16-bookworm --name "$CLUSTER_NAME" 2>/dev/null || \
  (docker pull postgres:16-bookworm && kind load docker-image postgres:16-bookworm --name "$CLUSTER_NAME")
kind load docker-image redis:7-bookworm --name "$CLUSTER_NAME" 2>/dev/null || \
  (docker pull redis:7-bookworm && kind load docker-image redis:7-bookworm --name "$CLUSTER_NAME")
kind load docker-image busybox:1.36 --name "$CLUSTER_NAME" 2>/dev/null || \
  (docker pull busybox:1.36 && kind load docker-image busybox:1.36 --name "$CLUSTER_NAME")

# ── 5. Namespace ──────────────────────────────────────────────────────
echo "[5/7] Criando namespace '$NAMESPACE' com Pod Security Standards..."
kubectl create namespace "$NAMESPACE" 2>/dev/null || echo "  Namespace já existe."
# PSS: enforce baseline, warn+audit restricted
kubectl label namespace "$NAMESPACE" \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=latest \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/audit-version=latest \
  --overwrite 2>/dev/null || true

# ── 6. Helm ───────────────────────────────────────────────────────────
# Desde 2026-09-13 este repo usa o platform-chart (não mais um chart
# bespoke) -- ver values.yaml. Local/kind não tem ExternalSecret (não há
# ClusterSecretStore fora do cluster real), então o secret é criado à
# mão via --set-string, sobrescrevendo secrets.create/existingSecret só
# nesta invocação (não commitar isso em values.yaml).
echo "[6/7] Fazendo deploy com Helm..."
echo ""
echo "  ATENÇÃO: Preencha as credenciais abaixo."
echo "  Pressione Enter para usar o valor entre colchetes."
echo ""
read -rp "  GOOGLE_CLIENT_ID [YOUR_GOOGLE_CLIENT_ID]: " GOOGLE_CLIENT_ID
GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-YOUR_GOOGLE_CLIENT_ID}"
read -rp "  GOOGLE_CLIENT_SECRET [YOUR_SECRET]: " GOOGLE_CLIENT_SECRET
GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-YOUR_SECRET}"

helm dependency build .

LOCAL_VALUES="$(mktemp)"
trap 'rm -f "$LOCAL_VALUES"' EXIT
cat > "$LOCAL_VALUES" <<EOF
platform-chart:
  ingress:
    enabled: false
  postgres:
    persistence:
      storageClassName: standard
  secrets:
    create: true
    existingSecret: ""
    data:
      POSTGRES_PASSWORD: devpassword
      DB_PASSWORD: devpassword
      JWT_SECRET: dev-jwt-secret-not-real
      GOOGLE_CLIENT_ID: "${GOOGLE_CLIENT_ID}"
      GOOGLE_CLIENT_SECRET: "${GOOGLE_CLIENT_SECRET}"
EOF

# extraEnv é uma lista -- Helm não faz merge de listas por -f, então os
# 3 primeiros --set-string sobrescrevem por índice (índices vêm do
# extraEnv base em values.yaml: 7=GOOGLE_CALLBACK_URL, 8=LOCAL_AUTH_ENABLED)
# e os 2 últimos ADICIONAM entradas novas (índices 10/11, um a mais que o
# tamanho atual da lista) só pra habilitar o login local de teste.
helm upgrade --install comprasweb . \
  -f "$LOCAL_VALUES" \
  -n "$NAMESPACE" \
  --timeout 8m \
  --set-string "platform-chart.api.extraEnv[7].value=http://localhost:3000/auth/google/callback" \
  --set-string "platform-chart.api.extraEnv[8].value=true" \
  --set-string "platform-chart.api.extraEnv[10].name=LOCAL_AUTH_USER" \
  --set-string "platform-chart.api.extraEnv[10].value=loadtest" \
  --set-string "platform-chart.api.extraEnv[11].name=LOCAL_AUTH_PASSWORD" \
  --set-string "platform-chart.api.extraEnv[11].value=loadtest123"

# ── 7. Port-forward ───────────────────────────────────────────────────
echo "[7/7] Iniciando port-forward em background..."
kubectl port-forward -n "$NAMESPACE" svc/comprasweb-api 3000:80 &
PF_PID=$!
sleep 3

if curl -sf http://localhost:3000/healthz > /dev/null; then
  echo ""
  echo "✓ Setup concluído!"
  echo ""
  echo "  App:      http://localhost:3000"
  echo "  Login:    http://localhost:3000/login"
  echo "  Teste:    http://localhost:3000/access  (user: loadtest / senha: loadtest123)"
  echo ""
  echo "  Monitorar logs:    kubectl logs -f -n $NAMESPACE -l app.kubernetes.io/component=api"
  echo "  Monitorar recursos: watch kubectl top pod -n $NAMESPACE"
  echo "  Port-forward PID:  $PF_PID"
else
  echo "✗ App não respondeu em localhost:3000. Verifique os pods:"
  kubectl get pods -n "$NAMESPACE"
fi
