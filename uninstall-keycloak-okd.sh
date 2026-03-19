#!/usr/bin/env bash
# ============================================================
# uninstall-keycloak-okd.sh
#
# Completely removes the Keycloak installation from OKD 4.
# Reads all names from keycloak-config.env.
#
# Usage:
#   chmod +x uninstall-keycloak-okd.sh
#   ./uninstall-keycloak-okd.sh
#
# Skip confirmation (CI):
#   ./uninstall-keycloak-okd.sh --yes
# ============================================================

set -euo pipefail

GREEN="\033[0;32m"; YELLOW="\033[1;33m"; RED="\033[0;31m"; NC="\033[0m"
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
skipped() { echo -e "  ${YELLOW}↷  skipped${NC} (not found)"; }
removed() { echo -e "  ${GREEN}✓  removed${NC}  $*"; }
divider() { echo -e "\n${GREEN}══════════════════════════════════════════════${NC}"; }

# ── Load config ────────────────────────────────────────────
divider
info "Loading configuration from keycloak-config.env..."
[[ -f "keycloak-config.env" ]] || \
  error "keycloak-config.env not found. Run from the package directory."

set -o allexport
# shellcheck disable=SC1090
source <(grep -v '^\s*#' keycloak-config.env | grep -v '^\s*$')
set +o allexport

info "Will remove:"
echo "  Namespace:    ${KEYCLOAK_NAMESPACE}"
echo "  Realm:        ${KC_REALM}"
echo "  IDP name:     ${KC_IDP_NAME}"
echo "  TLS mode:     ${KC_HOSTNAME_MODE}"

AUTO_YES=false
for arg in "$@"; do [[ "$arg" == "--yes" ]] && AUTO_YES=true; done

# ── Confirmation ───────────────────────────────────────────
divider
echo ""
echo -e "  ${RED}╔══════════════════════════════════════════════╗${NC}"
echo -e "  ${RED}║   WARNING: DESTRUCTIVE OPERATION             ║${NC}"
echo -e "  ${RED}║                                              ║${NC}"
echo -e "  ${RED}║   This will permanently delete:             ║${NC}"
echo -e "  ${RED}║     • Keycloak and all its data              ║${NC}"
echo -e "  ${RED}║     • The PostgreSQL database and PVC        ║${NC}"
echo -e "  ${RED}║     • Namespace: ${KEYCLOAK_NAMESPACE}$(printf '%*s' $((22-${#KEYCLOAK_NAMESPACE})) '')║${NC}"
echo -e "  ${RED}║     • OKD OAuth provider: ${KC_IDP_NAME}$(printf '%*s' $((17-${#KC_IDP_NAME})) '')║${NC}"
echo -e "  ${RED}║     • TLS secrets and all related CRDs       ║${NC}"
echo -e "  ${RED}╚══════════════════════════════════════════════╝${NC}"
echo ""

if [[ "$AUTO_YES" == false ]]; then
  read -r -p "  Type 'yes' to continue, anything else to abort: " CONFIRM
  [[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 0; }
fi

REALM_IMPORT_NAME="${KC_REALM}-realm-import"

# ── Step 1: Remove OAuth identity provider ─────────────────
divider
info "STEP 1/7 — Removing '${KC_IDP_NAME}' from OKD OAuth..."

if oc get oauth cluster &>/dev/null; then
  KC_INDEX=$(oc get oauth cluster -o json | \
    python3 -c "
import json, sys
obj = json.load(sys.stdin)
providers = obj.get('spec', {}).get('identityProviders', [])
for i, p in enumerate(providers):
    if p.get('name') == '${KC_IDP_NAME}':
        print(i)
        break
" 2>/dev/null || echo "")

  if [[ -n "$KC_INDEX" ]]; then
    oc patch oauth cluster --type=json \
      --patch="[{\"op\":\"remove\",\"path\":\"/spec/identityProviders/${KC_INDEX}\"}]"
    removed "identity provider '${KC_IDP_NAME}' from oauth/cluster"
    info "Waiting for OAuth rollout (up to 3 min)..."
    sleep 5
    oc -n openshift-authentication rollout status \
      deployment/oauth-openshift --timeout=180s || \
      warn "OAuth rollout timed out — may complete in background."
  else
    skipped; info "Provider '${KC_IDP_NAME}' not found in oauth/cluster."
  fi
else
  skipped; warn "oauth/cluster not found."
fi

if oc -n openshift-config get secret keycloak-client-secret &>/dev/null; then
  oc -n openshift-config delete secret keycloak-client-secret --ignore-not-found=true
  removed "secret/keycloak-client-secret (openshift-config)"
else
  echo -n "  keycloak-client-secret (openshift-config): "; skipped
fi

# ── Step 2: Remove Keycloak CRs ───────────────────────────
divider
info "STEP 2/7 — Removing Keycloak custom resources..."

if oc -n "${KEYCLOAK_NAMESPACE}" get keycloakrealmimport "${REALM_IMPORT_NAME}" &>/dev/null; then
  oc -n "${KEYCLOAK_NAMESPACE}" delete keycloakrealmimport "${REALM_IMPORT_NAME}" \
    --ignore-not-found=true
  removed "keycloakrealmimport/${REALM_IMPORT_NAME}"
else
  echo -n "  keycloakrealmimport/${REALM_IMPORT_NAME}: "; skipped
fi

if oc -n "${KEYCLOAK_NAMESPACE}" get keycloak keycloak &>/dev/null; then
  oc -n "${KEYCLOAK_NAMESPACE}" delete keycloak keycloak --ignore-not-found=true
  info "Waiting for Keycloak pod to terminate (up to 3 min)..."
  for i in $(seq 1 36); do
    COUNT=$(oc -n "${KEYCLOAK_NAMESPACE}" get pods -l app=keycloak \
      --no-headers 2>/dev/null | wc -l || echo 0)
    [[ "$COUNT" -eq 0 ]] && break
    sleep 5
    [[ $i -eq 36 ]] && warn "Keycloak pod did not terminate — continuing."
  done
  removed "keycloak/keycloak"
else
  echo -n "  keycloak/keycloak: "; skipped
fi

# ── Step 3: Remove Route ───────────────────────────────────
divider
info "STEP 3/7 — Removing Route..."
if oc -n "${KEYCLOAK_NAMESPACE}" get route keycloak &>/dev/null; then
  oc -n "${KEYCLOAK_NAMESPACE}" delete route keycloak --ignore-not-found=true
  removed "route/keycloak"
else
  echo -n "  route/keycloak: "; skipped
fi

# ── Step 4: Remove Operator ────────────────────────────────
divider
info "STEP 4/7 — Removing Keycloak Operator..."

if oc -n "${KEYCLOAK_NAMESPACE}" get subscription keycloak-operator &>/dev/null; then
  oc -n "${KEYCLOAK_NAMESPACE}" delete subscription keycloak-operator --ignore-not-found=true
  removed "subscription/keycloak-operator"
else
  echo -n "  subscription/keycloak-operator: "; skipped
fi

CSV=$(oc -n "${KEYCLOAK_NAMESPACE}" get csv -o name 2>/dev/null | grep keycloak || true)
if [[ -n "$CSV" ]]; then
  oc -n "${KEYCLOAK_NAMESPACE}" delete "$CSV" --ignore-not-found=true
  removed "$CSV"
else
  echo -n "  ClusterServiceVersion: "; skipped
fi

if oc -n "${KEYCLOAK_NAMESPACE}" get operatorgroup keycloak-operator-group &>/dev/null; then
  oc -n "${KEYCLOAK_NAMESPACE}" delete operatorgroup keycloak-operator-group \
    --ignore-not-found=true
  removed "operatorgroup/keycloak-operator-group"
else
  echo -n "  operatorgroup/keycloak-operator-group: "; skipped
fi

# ── Step 5: Remove PostgreSQL and PVC ─────────────────────
divider
info "STEP 5/7 — Removing PostgreSQL..."

if oc -n "${KEYCLOAK_NAMESPACE}" get statefulset postgresql-db &>/dev/null; then
  oc -n "${KEYCLOAK_NAMESPACE}" delete statefulset postgresql-db --ignore-not-found=true
  removed "statefulset/postgresql-db"
else
  echo -n "  statefulset/postgresql-db: "; skipped
fi

if oc -n "${KEYCLOAK_NAMESPACE}" get service postgres-db &>/dev/null; then
  oc -n "${KEYCLOAK_NAMESPACE}" delete service postgres-db --ignore-not-found=true
  removed "service/postgres-db"
else
  echo -n "  service/postgres-db: "; skipped
fi

if oc -n "${KEYCLOAK_NAMESPACE}" get pvc postgres-pvc &>/dev/null; then
  oc -n "${KEYCLOAK_NAMESPACE}" delete pvc postgres-pvc --ignore-not-found=true
  removed "pvc/postgres-pvc"
  warn "NFS data on the server is NOT auto-deleted."
  warn "Manually remove the data directory from StorageClass: ${DB_STORAGE_CLASS}"
else
  echo -n "  pvc/postgres-pvc: "; skipped
fi

# ── Step 6: Remove Secrets ────────────────────────────────
divider
info "STEP 6/7 — Removing Secrets..."

for secret in keycloak-db-secret keycloak-initial-admin keycloak-client-secret keycloak-tls; do
  if oc -n "${KEYCLOAK_NAMESPACE}" get secret "$secret" &>/dev/null; then
    oc -n "${KEYCLOAK_NAMESPACE}" delete secret "$secret" --ignore-not-found=true
    removed "secret/${secret} (${KEYCLOAK_NAMESPACE})"
  else
    echo -n "  secret/${secret}: "; skipped
  fi
done

# ── Step 7: CRDs and Namespace ─────────────────────────────
divider
info "STEP 7/7 — Removing CRDs and namespace '${KEYCLOAK_NAMESPACE}'..."

for crd in keycloaks.k8s.keycloak.org keycloakrealmimports.k8s.keycloak.org; do
  if oc get crd "$crd" &>/dev/null; then
    oc delete crd "$crd" --ignore-not-found=true
    removed "crd/$crd"
  else
    echo -n "  crd/$crd: "; skipped
  fi
done

if oc get namespace "${KEYCLOAK_NAMESPACE}" &>/dev/null; then
  oc delete namespace "${KEYCLOAK_NAMESPACE}" --ignore-not-found=true
  info "Waiting for namespace to terminate (up to 5 min)..."
  for i in $(seq 1 60); do
    NS=$(oc get namespace "${KEYCLOAK_NAMESPACE}" --no-headers 2>/dev/null \
      | awk '{print $2}' || true)
    [[ -z "$NS" ]] && break
    sleep 5
    [[ $i -eq 60 ]] && {
      warn "Namespace stuck in Terminating. Clear finalizers with:"
      warn "  oc patch namespace ${KEYCLOAK_NAMESPACE} \\"
      warn "    -p '{\"metadata\":{\"finalizers\":[]}}' --type=merge"
      break
    }
  done
  removed "namespace/${KEYCLOAK_NAMESPACE}"
else
  echo -n "  namespace/${KEYCLOAK_NAMESPACE}: "; skipped
fi

# ── Done ───────────────────────────────────────────────────
divider
echo ""
info "✅  Keycloak has been fully removed from OKD."
echo ""
warn "Users authenticated via '${KC_IDP_NAME}' can no longer log in."
warn "Ensure an alternative cluster-admin account is available."
echo ""
info "Verify:"
echo "  oc get namespace ${KEYCLOAK_NAMESPACE}"
echo "  oc get crd | grep keycloak"
echo "  oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}'"
echo ""
