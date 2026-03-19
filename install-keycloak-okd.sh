#!/usr/bin/env bash
# ============================================================
# install-keycloak-okd.sh
#
# Full end-to-end install of Keycloak on OKD 4.
# All configuration is read from keycloak-config.env.
#
# Supported TLS modes (KC_HOSTNAME_MODE in config):
#
#   auto       OKD assigns hostname automatically.
#              OKD router provides its own wildcard certificate.
#              No certificate files required.
#
#   edge       Custom hostname + your own TLS certificate.
#              TLS terminates at the OKD router.
#              Plain HTTP from router to Keycloak pod.
#              Requires: KC_HOSTNAME, KC_TLS_CERT, KC_TLS_KEY
#
#   reencrypt  Custom hostname + TLS all the way to the pod.
#              Router re-encrypts the connection to Keycloak.
#              Keycloak runs HTTPS internally.
#              Requires: KC_HOSTNAME, KC_TLS_CERT, KC_TLS_KEY,
#                        KC_TLS_CA_CERT
#
# Usage:
#   chmod +x install-keycloak-okd.sh
#   ./install-keycloak-okd.sh
# ============================================================

set -euo pipefail

GREEN="\033[0;32m"; YELLOW="\033[1;33m"; RED="\033[0;31m"; NC="\033[0m"
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
divider() { echo -e "\n${GREEN}══════════════════════════════════════════════${NC}"; }

# ── Load configuration ─────────────────────────────────────
divider
info "Loading configuration from keycloak-config.env..."
[[ -f "keycloak-config.env" ]] || \
  error "keycloak-config.env not found. Run from the package directory."

set -o allexport
# shellcheck disable=SC1090
source <(grep -v '^\s*#' keycloak-config.env | grep -v '^\s*$')
set +o allexport

# Validate required base config values
for var in KEYCLOAK_NAMESPACE OPERATOR_CHANNEL OPERATOR_INSTALL_APPROVAL \
           DB_USERNAME DB_PASSWORD DB_NAME DB_IMAGE \
           DB_STORAGE_CLASS DB_STORAGE_SIZE DB_ACCESS_MODE \
           DB_CPU_REQUEST DB_CPU_LIMIT DB_MEMORY_REQUEST DB_MEMORY_LIMIT \
           KC_INSTANCES KC_CPU_REQUEST KC_CPU_LIMIT KC_MEMORY_REQUEST KC_MEMORY_LIMIT \
           KC_REALM KC_REALM_DISPLAY_NAME KC_CLIENT_ID KC_IDP_NAME \
           KC_ACCESS_TOKEN_LIFESPAN KC_SSO_SESSION_IDLE KC_SSO_SESSION_MAX \
           KC_MAPPING_METHOD KC_PROMPT KC_HOSTNAME_MODE; do
  [[ -n "${!var:-}" ]] || \
    error "Missing required config value: ${var}. Check keycloak-config.env."
done

# ── Validate TLS mode and required files ───────────────────
KC_HOSTNAME_MODE="${KC_HOSTNAME_MODE,,}"
case "$KC_HOSTNAME_MODE" in
  auto)
    info "TLS mode: auto  (OKD-assigned hostname, OKD wildcard cert)"
    ;;
  edge)
    info "TLS mode: edge  (custom hostname, cert terminates at OKD router)"
    [[ -n "${KC_HOSTNAME:-}" ]] || error "KC_HOSTNAME required for mode=edge"
    [[ -n "${KC_TLS_CERT:-}" ]] || error "KC_TLS_CERT required for mode=edge"
    [[ -n "${KC_TLS_KEY:-}" ]]  || error "KC_TLS_KEY required for mode=edge"
    [[ -f "${KC_TLS_CERT}" ]]   || error "KC_TLS_CERT not found: ${KC_TLS_CERT}"
    [[ -f "${KC_TLS_KEY}" ]]    || error "KC_TLS_KEY not found: ${KC_TLS_KEY}"
    ;;
  reencrypt)
    info "TLS mode: reencrypt  (custom hostname, TLS end-to-end to pod)"
    [[ -n "${KC_HOSTNAME:-}" ]]    || error "KC_HOSTNAME required for mode=reencrypt"
    [[ -n "${KC_TLS_CERT:-}" ]]    || error "KC_TLS_CERT required for mode=reencrypt"
    [[ -n "${KC_TLS_KEY:-}" ]]     || error "KC_TLS_KEY required for mode=reencrypt"
    [[ -n "${KC_TLS_CA_CERT:-}" ]] || error "KC_TLS_CA_CERT required for mode=reencrypt"
    [[ -f "${KC_TLS_CERT}" ]]      || error "KC_TLS_CERT not found: ${KC_TLS_CERT}"
    [[ -f "${KC_TLS_KEY}" ]]       || error "KC_TLS_KEY not found: ${KC_TLS_KEY}"
    [[ -f "${KC_TLS_CA_CERT}" ]]   || error "KC_TLS_CA_CERT not found: ${KC_TLS_CA_CERT}"
    ;;
  *)
    error "KC_HOSTNAME_MODE must be: auto, edge, or reencrypt. Got: ${KC_HOSTNAME_MODE}"
    ;;
esac

info "Configuration:"
echo "  Namespace:        ${KEYCLOAK_NAMESPACE}"
echo "  Operator channel: ${OPERATOR_CHANNEL}  (approval: ${OPERATOR_INSTALL_APPROVAL})"
echo "  DB storage class: ${DB_STORAGE_CLASS}  (${DB_STORAGE_SIZE}, ${DB_ACCESS_MODE})"
echo "  KC instances:     ${KC_INSTANCES}"
echo "  Realm:            ${KC_REALM}  (client: ${KC_CLIENT_ID})"
echo "  IDP name:         ${KC_IDP_NAME}"
echo "  Hostname mode:    ${KC_HOSTNAME_MODE}"
[[ "$KC_HOSTNAME_MODE" != "auto" ]] && echo "  Custom hostname:  ${KC_HOSTNAME}"

# ── Preflight checks ───────────────────────────────────────
divider
info "Checking prerequisites..."
command -v oc      &>/dev/null || error "'oc' CLI not found."
command -v openssl &>/dev/null || error "'openssl' not found."
oc whoami &>/dev/null          || error "Not logged in. Run 'oc login' first."
info "Logged in as: $(oc whoami)"

for f in 01-operator.yaml 02-postgres.yaml 03-keycloak.yaml 04-realm-and-oauth.yaml; do
  [[ -f "$f" ]] || error "Missing required file: $f"
done

# ── Template renderer ──────────────────────────────────────
render() {
  local file="$1"; shift
  sed \
    -e "s|KEYCLOAK_NAMESPACE|${KEYCLOAK_NAMESPACE}|g" \
    -e "s|OPERATOR_CHANNEL|${OPERATOR_CHANNEL}|g" \
    -e "s|OPERATOR_INSTALL_APPROVAL|${OPERATOR_INSTALL_APPROVAL}|g" \
    -e "s|DB_STORAGE_CLASS|${DB_STORAGE_CLASS}|g" \
    -e "s|DB_STORAGE_SIZE|${DB_STORAGE_SIZE}|g" \
    -e "s|DB_ACCESS_MODE|${DB_ACCESS_MODE}|g" \
    -e "s|DB_USERNAME|${DB_USERNAME}|g" \
    -e "s|DB_PASSWORD|${DB_PASSWORD}|g" \
    -e "s|DB_NAME|${DB_NAME}|g" \
    -e "s|DB_IMAGE|${DB_IMAGE}|g" \
    -e "s|DB_CPU_REQUEST|${DB_CPU_REQUEST}|g" \
    -e "s|DB_CPU_LIMIT|${DB_CPU_LIMIT}|g" \
    -e "s|DB_MEMORY_REQUEST|${DB_MEMORY_REQUEST}|g" \
    -e "s|DB_MEMORY_LIMIT|${DB_MEMORY_LIMIT}|g" \
    -e "s|KC_INSTANCES|${KC_INSTANCES}|g" \
    -e "s|KC_CPU_REQUEST|${KC_CPU_REQUEST}|g" \
    -e "s|KC_CPU_LIMIT|${KC_CPU_LIMIT}|g" \
    -e "s|KC_MEMORY_REQUEST|${KC_MEMORY_REQUEST}|g" \
    -e "s|KC_MEMORY_LIMIT|${KC_MEMORY_LIMIT}|g" \
    -e "s|KC_REALM_DISPLAY_NAME|${KC_REALM_DISPLAY_NAME}|g" \
    -e "s|KC_REALM|${KC_REALM}|g" \
    -e "s|KC_CLIENT_ID|${KC_CLIENT_ID}|g" \
    -e "s|KC_IDP_NAME|${KC_IDP_NAME}|g" \
    -e "s|KC_ACCESS_TOKEN_LIFESPAN|${KC_ACCESS_TOKEN_LIFESPAN}|g" \
    -e "s|KC_SSO_SESSION_IDLE|${KC_SSO_SESSION_IDLE}|g" \
    -e "s|KC_SSO_SESSION_MAX|${KC_SSO_SESSION_MAX}|g" \
    -e "s|KC_MAPPING_METHOD|${KC_MAPPING_METHOD}|g" \
    -e "s|KC_PROMPT|${KC_PROMPT}|g" \
    "$@" \
    "$file"
}

# ── Detect cluster domain ──────────────────────────────────
divider
info "Detecting cluster apps domain..."
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster \
  -o jsonpath='{.spec.domain}' 2>/dev/null || true)
[[ -n "$CLUSTER_DOMAIN" ]] || \
  error "Could not detect cluster domain."
info "Cluster domain: ${CLUSTER_DOMAIN}"

info "Generating OIDC client secret..."
CLIENT_SECRET=$(openssl rand -base64 32)

# ── Step 1: Install Operator ───────────────────────────────
divider
info "STEP 1/7 — Installing Keycloak Operator..."
render 01-operator.yaml | oc apply -f -

info "Waiting for InstallPlan (up to 2.5 min)..."
for i in $(seq 1 30); do
  IP=$(oc -n "${KEYCLOAK_NAMESPACE}" get installplan -o name 2>/dev/null | head -1 || true)
  [[ -n "$IP" ]] && break
  sleep 5
  [[ $i -eq 30 ]] && error "Timed out waiting for InstallPlan."
done
oc -n "${KEYCLOAK_NAMESPACE}" patch "${IP}" --type merge --patch '{"spec":{"approved":true}}'
info "InstallPlan approved: ${IP}"

info "Waiting for operator CSV (up to 5 min)..."
for i in $(seq 1 60); do
  PHASE=$(oc -n "${KEYCLOAK_NAMESPACE}" get csv \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
  [[ "$PHASE" == "Succeeded" ]] && break
  sleep 5
  [[ $i -eq 60 ]] && error "Operator CSV did not reach Succeeded."
done
info "Operator installed."

for crd in keycloaks.k8s.keycloak.org keycloakrealmimports.k8s.keycloak.org; do
  oc get crd "$crd" &>/dev/null || error "CRD not found: $crd"
  info "  ✓ $crd"
done

# ── Step 2: Deploy PostgreSQL ──────────────────────────────
divider
info "STEP 2/7 — Deploying PostgreSQL..."
render 02-postgres.yaml | oc apply -f -

if oc -n "${KEYCLOAK_NAMESPACE}" get secret keycloak-db-secret &>/dev/null; then
  warn "keycloak-db-secret already exists — skipping."
else
  oc -n "${KEYCLOAK_NAMESPACE}" create secret generic keycloak-db-secret \
    --from-literal=username="${DB_USERNAME}" \
    --from-literal=password="${DB_PASSWORD}"
fi

oc -n "${KEYCLOAK_NAMESPACE}" wait --for=condition=ready pod \
  -l app=postgresql-db --timeout=180s
info "PostgreSQL ready."

# ── Step 3: TLS secrets + Route ───────────────────────────
divider
info "STEP 3/7 — Configuring TLS and creating Route (mode: ${KC_HOSTNAME_MODE})..."

# Build the Keycloak CR http and proxy blocks based on TLS mode.
# These are injected into 03-keycloak.yaml at apply time.

case "$KC_HOSTNAME_MODE" in

  # ── AUTO ──────────────────────────────────────────────────
  auto)
    oc apply -f - <<ROUTE_EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: keycloak
  namespace: ${KEYCLOAK_NAMESPACE}
spec:
  to:
    kind: Service
    name: keycloak-service
  port:
    targetPort: 8080
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
ROUTE_EOF

    KEYCLOAK_HOST=$(oc -n "${KEYCLOAK_NAMESPACE}" get route keycloak \
      -o jsonpath='{.spec.host}')
    [[ -n "$KEYCLOAK_HOST" ]] || error "Route hostname is empty."
    info "Auto-assigned hostname: ${KEYCLOAK_HOST}"

    KC_HTTP_BLOCK="  http:\n    httpEnabled: true"
    KC_PROXY_BLOCK="  proxy:\n    headers: xforwarded"
    ;;

  # ── EDGE ──────────────────────────────────────────────────
  edge)
    KEYCLOAK_HOST="${KC_HOSTNAME}"

    info "Creating TLS secret 'keycloak-tls'..."
    if oc -n "${KEYCLOAK_NAMESPACE}" get secret keycloak-tls &>/dev/null; then
      warn "Secret 'keycloak-tls' exists — deleting and recreating."
      oc -n "${KEYCLOAK_NAMESPACE}" delete secret keycloak-tls
    fi
    oc -n "${KEYCLOAK_NAMESPACE}" create secret tls keycloak-tls \
      --cert="${KC_TLS_CERT}" \
      --key="${KC_TLS_KEY}"
    info "TLS secret created."

    info "Creating edge Route for ${KEYCLOAK_HOST}..."
    oc apply -f - <<ROUTE_EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: keycloak
  namespace: ${KEYCLOAK_NAMESPACE}
spec:
  host: ${KEYCLOAK_HOST}
  to:
    kind: Service
    name: keycloak-service
  port:
    targetPort: 8080
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
    certificate: |
$(sed 's/^/      /' "${KC_TLS_CERT}")
    key: |
$(sed 's/^/      /' "${KC_TLS_KEY}")
ROUTE_EOF

    KC_HTTP_BLOCK="  http:\n    httpEnabled: true"
    KC_PROXY_BLOCK="  proxy:\n    headers: xforwarded"
    ;;

  # ── REENCRYPT ─────────────────────────────────────────────
  reencrypt)
    KEYCLOAK_HOST="${KC_HOSTNAME}"

    info "Creating TLS secret 'keycloak-tls' for Keycloak pod..."
    if oc -n "${KEYCLOAK_NAMESPACE}" get secret keycloak-tls &>/dev/null; then
      warn "Secret 'keycloak-tls' exists — deleting and recreating."
      oc -n "${KEYCLOAK_NAMESPACE}" delete secret keycloak-tls
    fi
    oc -n "${KEYCLOAK_NAMESPACE}" create secret tls keycloak-tls \
      --cert="${KC_TLS_CERT}" \
      --key="${KC_TLS_KEY}"
    info "TLS secret created."

    info "Creating reencrypt Route for ${KEYCLOAK_HOST}..."
    oc apply -f - <<ROUTE_EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: keycloak
  namespace: ${KEYCLOAK_NAMESPACE}
spec:
  host: ${KEYCLOAK_HOST}
  to:
    kind: Service
    name: keycloak-service
  port:
    targetPort: 8443
  tls:
    termination: reencrypt
    insecureEdgeTerminationPolicy: Redirect
    certificate: |
$(sed 's/^/      /' "${KC_TLS_CERT}")
    key: |
$(sed 's/^/      /' "${KC_TLS_KEY}")
    destinationCACertificate: |
$(sed 's/^/      /' "${KC_TLS_CA_CERT}")
ROUTE_EOF

    # Keycloak runs HTTPS internally — reference the TLS secret
    KC_HTTP_BLOCK="  http:\n    httpEnabled: false\n    tlsSecret: keycloak-tls"
    KC_PROXY_BLOCK=""
    ;;
esac

info "Route ready — hostname: ${KEYCLOAK_HOST}"

# ── Step 4: Deploy Keycloak ────────────────────────────────
divider
info "STEP 4/7 — Deploying Keycloak (${KC_INSTANCES} instance(s), mode: ${KC_HOSTNAME_MODE})..."

# Use printf to correctly expand \n in the block variables before sed injection
HTTP_BLOCK_EXPANDED=$(printf '%s' "${KC_HTTP_BLOCK}")
PROXY_BLOCK_EXPANDED=$(printf '%s' "${KC_PROXY_BLOCK}")

render 03-keycloak.yaml \
  -e "s|KEYCLOAK_HOST|${KEYCLOAK_HOST}|g" | \
  awk \
    -v http_block="${HTTP_BLOCK_EXPANDED}" \
    -v proxy_block="${PROXY_BLOCK_EXPANDED}" \
    '{
      if (/^KC_HTTP_BLOCK$/)  { if (http_block  != "") print http_block;  next }
      if (/^KC_PROXY_BLOCK$/) { if (proxy_block != "") print proxy_block; next }
      print
    }' | \
  oc apply -f -

info "Waiting for Keycloak to be ready (up to 10 min)..."
for i in $(seq 1 120); do
  READY=$(oc -n "${KEYCLOAK_NAMESPACE}" get keycloak keycloak \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  [[ "$READY" == "True" ]] && break
  sleep 5
  [[ $i -eq 120 ]] && {
    warn "Check logs: oc -n ${KEYCLOAK_NAMESPACE} logs deployment/keycloak"
    error "Keycloak did not become ready in time."
  }
done
info "Keycloak ready."

# ── Step 5: Admin credentials ─────────────────────────────
divider
info "STEP 5/7 — Retrieving initial admin credentials..."
ADMIN_USER=$(oc -n "${KEYCLOAK_NAMESPACE}" get secret keycloak-initial-admin \
  -o jsonpath='{.data.username}' | base64 -d)
ADMIN_PASS=$(oc -n "${KEYCLOAK_NAMESPACE}" get secret keycloak-initial-admin \
  -o jsonpath='{.data.password}' | base64 -d)

echo ""
echo -e "  ${YELLOW}Keycloak Admin Console:${NC}  https://${KEYCLOAK_HOST}"
echo -e "  ${YELLOW}Username:${NC}                ${ADMIN_USER}"
echo -e "  ${YELLOW}Password:${NC}                ${ADMIN_PASS}"
echo ""
warn "Save these credentials — keycloak-initial-admin may be deleted after first login."

# ── Step 6: Realm import and OAuth ────────────────────────
divider
info "STEP 6/7 — Applying realm import and OKD OAuth integration..."

if oc -n openshift-config get secret keycloak-client-secret &>/dev/null; then
  warn "keycloak-client-secret already exists in openshift-config — skipping."
else
  oc -n openshift-config create secret generic keycloak-client-secret \
    --from-literal=clientSecret="${CLIENT_SECRET}"
fi

render 04-realm-and-oauth.yaml \
  -e "s|KEYCLOAK_HOST|${KEYCLOAK_HOST}|g" \
  -e "s|CLUSTER_DOMAIN|${CLUSTER_DOMAIN}|g" \
  -e "s|CLIENT_SECRET|${CLIENT_SECRET}|g" | \
  grep -v '^\s*#' | \
  oc apply -f - 2>/dev/null || true

info "Patching oauth/cluster (provider: ${KC_IDP_NAME})..."
EXISTING=$(oc get oauth cluster \
  -o jsonpath="{.spec.identityProviders[?(@.name==\"${KC_IDP_NAME}\")].name}" \
  2>/dev/null || true)

if [[ "$EXISTING" == "${KC_IDP_NAME}" ]]; then
  warn "Identity provider '${KC_IDP_NAME}' already present — skipping."
else
  ISSUER_URL="https://${KEYCLOAK_HOST}/realms/${KC_REALM}"
  EXISTING_PROVIDERS=$(oc get oauth cluster \
    -o jsonpath='{.spec.identityProviders}' 2>/dev/null || echo "")

  IDP_JSON=$(cat <<EOIPD
{
  "name": "${KC_IDP_NAME}",
  "mappingMethod": "${KC_MAPPING_METHOD}",
  "type": "OpenID",
  "openID": {
    "clientID": "${KC_CLIENT_ID}",
    "clientSecret": { "name": "keycloak-client-secret" },
    "claims": {
      "preferredUsername": ["preferred_username"],
      "name":  ["name"],
      "email": ["email"],
      "groups":["groups"]
    },
    "issuer": "${ISSUER_URL}",
    "extraScopes": ["email", "profile"],
    "extraAuthorizeParameters": { "prompt": "${KC_PROMPT}" }
  }
}
EOIPD
  )

  if [[ -z "$EXISTING_PROVIDERS" || "$EXISTING_PROVIDERS" == "[]" ]]; then
    oc patch oauth cluster --type=merge \
      --patch="{\"spec\":{\"identityProviders\":[${IDP_JSON}]}}"
  else
    oc patch oauth cluster --type=json \
      --patch="[{\"op\":\"add\",\"path\":\"/spec/identityProviders/-\",\"value\":${IDP_JSON}}]"
  fi
  info "oauth/cluster patched."
fi

REALM_IMPORT_NAME="${KC_REALM}-realm-import"
info "Waiting for realm import (up to 3 min)..."
for i in $(seq 1 36); do
  DONE=$(oc -n "${KEYCLOAK_NAMESPACE}" get keycloakrealmimport "${REALM_IMPORT_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="Done")].status}' 2>/dev/null || true)
  [[ "$DONE" == "True" ]] && break
  sleep 5
  [[ $i -eq 36 ]] && {
    warn "Realm import timed out."
    warn "Check: oc -n ${KEYCLOAK_NAMESPACE} describe keycloakrealmimport ${REALM_IMPORT_NAME}"
  }
done
info "Realm import complete."

# ── Step 7: OAuth rollout ──────────────────────────────────
divider
info "STEP 7/7 — Waiting for OKD OAuth pods to roll out (up to 3 min)..."
sleep 10
oc -n openshift-authentication rollout status \
  deployment/oauth-openshift --timeout=180s
info "OAuth rollout complete."

# ── Done ───────────────────────────────────────────────────
divider
echo ""
info "✅  Keycloak installation complete!"
echo ""
echo -e "  ${YELLOW}Keycloak Admin Console:${NC}  https://${KEYCLOAK_HOST}"
echo -e "  ${YELLOW}TLS mode:${NC}                ${KC_HOSTNAME_MODE}"
echo -e "  ${YELLOW}Realm:${NC}                   ${KC_REALM}"
echo -e "  ${YELLOW}OKD login provider:${NC}      ${KC_IDP_NAME}"
echo ""
info "Next steps:"
echo "  1. Log into the Keycloak admin console and create your users."
echo "  2. Open the OKD console — select '${KC_IDP_NAME}' as the identity provider."
echo "  3. Grant cluster roles: oc adm policy add-cluster-role-to-user cluster-admin <user>"
echo ""
if [[ "$KC_HOSTNAME_MODE" != "auto" ]]; then
  warn "Ensure ${KEYCLOAK_HOST} resolves to your OKD router in DNS."
fi
warn "Update DB_USERNAME / DB_PASSWORD in keycloak-config.env before going to production."
