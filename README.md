# Keycloak on OKD 4

[![Platform](https://img.shields.io/badge/platform-OKD%204.x-informational?logo=redhatopenshift&logoColor=white)](https://okd.io)
[![Operator](https://img.shields.io/badge/operator-Keycloak%20Community-success?logo=keycloak&logoColor=white)](https://www.keycloak.org/operator/installation)
[![Channel](https://img.shields.io/badge/OLM%20channel-fast-blue)](https://operatorhub.io/operator/keycloak-operator)
[![License](https://img.shields.io/badge/license-MIT-lightgrey)](LICENSE)

> **Community Keycloak Operator · OLM · NFS Persistent Storage · OpenID Connect · OKD 4.x**

Installs the upstream [Keycloak Operator](https://www.keycloak.org/operator/installation) into OKD 4 via the Operator Lifecycle Manager, deploys a PostgreSQL-backed Keycloak instance, and integrates it with the OKD OAuth server as an OpenID Connect identity provider — all from a single shell script driven by one configuration file.

---

## Table of Contents

- [Package Contents](#package-contents)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Configuration Reference](#configuration-reference)
  - [Namespace and Operator](#namespace-and-operator)
  - [PostgreSQL](#postgresql)
  - [Keycloak Instance](#keycloak-instance)
  - [Hostname and TLS](#hostname-and-tls)
  - [Realm and OAuth](#realm-and-oauth)
- [TLS Modes](#tls-modes)
  - [auto](#auto--okd-wildcard-certificate)
  - [edge](#edge--custom-certificate-tls-at-router)
  - [reencrypt](#reencrypt--end-to-end-tls)
- [Installation Steps](#installation-steps)
- [After Installation](#after-installation)
- [Uninstallation](#uninstallation)
- [Troubleshooting](#troubleshooting)
- [OKD vs OCP Differences](#okd-vs-ocp-differences)
- [Production Checklist](#production-checklist)

---

## Package Contents

```
keycloak-okd-complete.zip
├── keycloak-config.env          # ← Edit this before running anything
├── install-keycloak-okd.sh      # Master install script
├── uninstall-keycloak-okd.sh    # Complete removal script
├── 01-operator.yaml             # Namespace, OperatorGroup, Subscription
├── 02-postgres.yaml             # NFS PVC, PostgreSQL StatefulSet + Service
├── 03-keycloak.yaml             # Keycloak CR + OKD Route
└── 04-realm-and-oauth.yaml      # KeycloakRealmImport
```

> **Note:** The YAML files contain placeholder tokens (e.g. `KEYCLOAK_NAMESPACE`, `DB_STORAGE_CLASS`). They are never applied directly — the install script substitutes all values from `keycloak-config.env` at runtime.

---

## Architecture

```
  Browser / oc CLI
        |
        | HTTPS
        v
  OKD Router ──────────────── TLS termination (edge or reencrypt)
        |
        | HTTP or HTTPS (depends on KC_HOSTNAME_MODE)
        v
  oauth-openshift pod ─────── OKD OAuth server
        |
        | OIDC redirect  (prompt=login enforced)
        v
  Keycloak pod ────────────── namespace: keycloak  port: 8080 or 8443
        |
        | JDBC
        v
  PostgreSQL ──────────────── PVC: nfs-storage, 10Gi
```

**TLS flow by mode:**

| Mode | Router → Pod | Keycloak port |
|---|---|---|
| `auto` | Plain HTTP, OKD wildcard cert at router | 8080 |
| `edge` | Plain HTTP, your cert at router | 8080 |
| `reencrypt` | HTTPS, your cert at router **and** pod | 8443 |

---

## Prerequisites

| Requirement | How to verify |
|---|---|
| OKD 4.10 or later | `oc version` |
| Logged in as `cluster-admin` | `oc whoami && oc auth can-i '*' '*' --all-namespaces` |
| `openssl` available | `openssl version` |
| NFS StorageClass available | `oc get storageclass` |
| All 7 package files in the same directory | `ls *.yaml *.sh *.env` |
| *(edge/reencrypt only)* TLS cert and key files accessible on the machine running the script | `ls $KC_TLS_CERT $KC_TLS_KEY` |

> **Important:** Before installing Keycloak as an identity provider, ensure at least one `cluster-admin` account exists that does **not** authenticate via Keycloak (e.g. `kubeadmin` or an htpasswd user). If Keycloak becomes unavailable you will need this account to recover.

---

## Quick Start

### 1. Extract the package

```bash
unzip keycloak-okd-complete.zip -d keycloak-okd
cd keycloak-okd
```

### 2. Edit the configuration file

```bash
# Minimum values to set before running:
#   DB_STORAGE_CLASS   — your NFS StorageClass name (oc get storageclass)
#   DB_PASSWORD        — strong database password
#   KC_HOSTNAME_MODE   — auto | edge | reencrypt
#   KC_HOSTNAME        — required for edge and reencrypt
#   KC_TLS_CERT        — required for edge and reencrypt
#   KC_TLS_KEY         — required for edge and reencrypt
#   KC_TLS_CA_CERT     — required for reencrypt only

nano keycloak-config.env
```

### 3. Run the install script

```bash
chmod +x install-keycloak-okd.sh
./install-keycloak-okd.sh
```

The script runs unattended (~10–15 minutes) and prints the Keycloak admin URL and credentials on completion.

---

## Configuration Reference

All configuration lives in **`keycloak-config.env`**. The install and uninstall scripts source this file at startup and substitute every value into the YAML templates.

### Namespace and Operator

| Variable | Default | Description |
|---|---|---|
| `KEYCLOAK_NAMESPACE` | `keycloak` | Namespace for all Keycloak resources |
| `OPERATOR_CHANNEL` | `fast` | OLM channel. `fast` tracks latest upstream releases |
| `OPERATOR_INSTALL_APPROVAL` | `Manual` | `Manual` (recommended) prevents unintended upgrades that may run irreversible DB migrations. Use `Automatic` with caution |

### PostgreSQL

| Variable | Default | Description |
|---|---|---|
| `DB_USERNAME` | `keycloak` | PostgreSQL username |
| `DB_PASSWORD` | `changeme_...` | PostgreSQL password. **Must change before production** |
| `DB_NAME` | `keycloak` | Database name |
| `DB_IMAGE` | `postgres:15` | Container image |
| `DB_STORAGE_CLASS` | `nfs-storage` | StorageClass name — run `oc get storageclass` to confirm yours |
| `DB_STORAGE_SIZE` | `10Gi` | PVC size |
| `DB_ACCESS_MODE` | `ReadWriteMany` | `ReadWriteMany` for NFS · `ReadWriteOnce` for block storage |
| `DB_CPU_REQUEST` | `250m` | |
| `DB_CPU_LIMIT` | `500m` | |
| `DB_MEMORY_REQUEST` | `256Mi` | |
| `DB_MEMORY_LIMIT` | `512Mi` | |

### Keycloak Instance

| Variable | Default | Description |
|---|---|---|
| `KC_INSTANCES` | `1` | Replicas. Use `2` or more for production HA |
| `KC_CPU_REQUEST` | `500m` | |
| `KC_CPU_LIMIT` | `2` | |
| `KC_MEMORY_REQUEST` | `1Gi` | Minimum for Quarkus/Keycloak |
| `KC_MEMORY_LIMIT` | `2Gi` | |

### Hostname and TLS

| Variable | Default | Description |
|---|---|---|
| `KC_HOSTNAME_MODE` | `auto` | TLS mode: `auto`, `edge`, or `reencrypt`. See [TLS Modes](#tls-modes) |
| `KC_HOSTNAME` | *(empty)* | Custom hostname e.g. `keycloak.mydomain.com`. Required for `edge` and `reencrypt` |
| `KC_TLS_CERT` | *(empty)* | Path to PEM certificate file (fullchain recommended). Required for `edge` and `reencrypt` |
| `KC_TLS_KEY` | *(empty)* | Path to PEM private key. Required for `edge` and `reencrypt` |
| `KC_TLS_CA_CERT` | *(empty)* | Path to the CA certificate used by the OKD router to verify the pod's certificate. Required for `reencrypt` only |

### Realm and OAuth

| Variable | Default | Description |
|---|---|---|
| `KC_REALM` | `okd` | Keycloak realm name |
| `KC_REALM_DISPLAY_NAME` | `OKD` | Display name in Keycloak admin console |
| `KC_CLIENT_ID` | `okd` | OIDC client ID registered in the realm |
| `KC_IDP_NAME` | `keycloak` | Name shown on the OKD console login page |
| `KC_ACCESS_TOKEN_LIFESPAN` | `300` | Access token lifespan in seconds (5 min) |
| `KC_SSO_SESSION_IDLE` | `1800` | SSO session idle timeout in seconds (30 min) |
| `KC_SSO_SESSION_MAX` | `36000` | SSO session max lifespan in seconds (10 hours) |
| `KC_MAPPING_METHOD` | `claim` | `claim` maps `sub` to OKD identity · `lookup` requires pre-provisioned users |
| `KC_PROMPT` | `login` | Forces Keycloak login screen on every request. Leave empty to allow SSO passthrough |

---

## TLS Modes

### `auto` — OKD wildcard certificate

OKD assigns a hostname automatically under the cluster apps domain (e.g. `keycloak-keycloak.apps.mycluster.example.com`) and uses its own wildcard certificate. No certificate files are needed.

**Use for:** development, testing, and clusters where the OKD wildcard cert is trusted.

```bash
# keycloak-config.env
KC_HOSTNAME_MODE=auto
# KC_HOSTNAME, KC_TLS_CERT, KC_TLS_KEY not required
```

---

### `edge` — Custom certificate, TLS at router

You provide a custom hostname and your own TLS certificate. TLS terminates at the OKD router; traffic from the router to the Keycloak pod is plain HTTP on port 8080.

**Use for:** production with a custom domain and a certificate from a public or internal CA.

```bash
# keycloak-config.env
KC_HOSTNAME_MODE=edge
KC_HOSTNAME=keycloak.mydomain.com
KC_TLS_CERT=/etc/ssl/certs/keycloak-fullchain.pem
KC_TLS_KEY=/etc/ssl/private/keycloak.key
```

The script creates an OKD `TLS` secret named `keycloak-tls` in the `keycloak` namespace and embeds the certificate in the Route.

> **Tip:** Use a fullchain certificate that includes intermediate CA certificates. This avoids browser trust warnings.

---

### `reencrypt` — End-to-end TLS

The most secure option. TLS is maintained end-to-end — the OKD router decrypts the incoming connection and re-encrypts it to the Keycloak pod. Keycloak runs HTTPS internally on port 8443.

**Use for:** high-security environments, compliance requirements, or where internal cluster traffic must be encrypted.

```bash
# keycloak-config.env
KC_HOSTNAME_MODE=reencrypt
KC_HOSTNAME=keycloak.mydomain.com
KC_TLS_CERT=/etc/ssl/certs/keycloak.crt
KC_TLS_KEY=/etc/ssl/private/keycloak.key
KC_TLS_CA_CERT=/etc/ssl/certs/internal-ca.crt
```

`KC_TLS_CA_CERT` is the CA that signed the certificate the **pod** presents. The OKD router uses this to validate the backend connection. It does not need to be the same CA as the router-facing certificate, though it often is.

> **DNS:** For `edge` and `reencrypt`, your custom hostname must resolve to the OKD router's IP in DNS before the OKD OAuth server can redirect users to Keycloak.

---

## Installation Steps

The install script performs 7 steps in sequence, waiting for each to complete before proceeding.

<details>
<summary><strong>Step 1 — Install the Keycloak Operator</strong></summary>

Applies `01-operator.yaml` to create the namespace, `OperatorGroup`, and OLM `Subscription` using the `community-operators` catalog on the `fast` channel with `Manual` install plan approval.

- Waits for the `InstallPlan` to appear (up to 2.5 min) and approves it automatically
- Waits for the `ClusterServiceVersion` to reach `Succeeded` (up to 5 min)
- Verifies both Keycloak CRDs are registered: `keycloaks.k8s.keycloak.org` and `keycloakrealmimports.k8s.keycloak.org`

</details>

<details>
<summary><strong>Step 2 — Deploy PostgreSQL</strong></summary>

Applies `02-postgres.yaml` — creates the NFS `PersistentVolumeClaim`, PostgreSQL `StatefulSet`, and `postgres-db` Service. Creates the `keycloak-db-secret` from `DB_USERNAME` and `DB_PASSWORD`.

</details>

<details>
<summary><strong>Step 3 — Configure TLS and create the Route</strong></summary>

Behaviour depends on `KC_HOSTNAME_MODE`:

- **`auto`** — Creates a plain `edge` Route with no `host` field; OKD assigns the hostname
- **`edge`** — Creates the `keycloak-tls` secret, then creates an `edge` Route with your hostname and certificate embedded inline
- **`reencrypt`** — Creates the `keycloak-tls` secret, then creates a `reencrypt` Route with your hostname, certificate, and `destinationCACertificate` on port 8443

The Route is created **before** the Keycloak CR because Keycloak 26+ requires the hostname at startup — OKD assigns it as soon as the Route object exists.

</details>

<details>
<summary><strong>Step 4 — Deploy Keycloak</strong></summary>

Substitutes the Route hostname and the appropriate `http`/`proxy` configuration block into `03-keycloak.yaml` and applies the `Keycloak` CR. Waits up to 10 minutes for `Ready`.

The CR is configured with:

| Setting | `auto` / `edge` | `reencrypt` |
|---|---|---|
| `http.httpEnabled` | `true` | `false` |
| `http.tlsSecret` | *(not set)* | `keycloak-tls` |
| `proxy.headers` | `xforwarded` | *(not set)* |
| `ingress.enabled` | `false` | `false` |

</details>

<details>
<summary><strong>Step 5 — Retrieve admin credentials</strong></summary>

Reads the `keycloak-initial-admin` secret and prints the admin URL, username, and password.

> **Save these immediately.** Keycloak deletes the `keycloak-initial-admin` secret after the first admin login.

</details>

<details>
<summary><strong>Step 6 — Realm import and OAuth integration</strong></summary>

- Generates a random 32-byte OIDC client secret with `openssl rand -base64 32`
- Creates `keycloak-client-secret` in `openshift-config`
- Applies the `KeycloakRealmImport` CR from `04-realm-and-oauth.yaml`
- Patches `oauth/cluster` using `oc patch --type=json` to **append** the Keycloak provider without overwriting existing ones

> **Why `oc patch` instead of `oc apply`?** The `oauth/cluster` resource is a cluster-level singleton that already exists in every OKD cluster. `oc apply` fails with `metadata.resourceVersion: Invalid value: 0: must be specified for an update`. The script uses a JSON Patch `add` operation on `/spec/identityProviders/-` to safely append the new provider.

</details>

<details>
<summary><strong>Step 7 — Wait for OAuth rollout</strong></summary>

Waits for the `oauth-openshift` deployment in `openshift-authentication` to roll out. After this, the Keycloak option appears on the OKD console login page.

</details>

---

## After Installation

### Access the Admin Console

The admin URL is printed at the end of the install. Retrieve it later with:

```bash
echo "https://$(oc -n keycloak get route keycloak -o jsonpath='{.spec.host}')"
```

Retrieve the initial credentials if you missed them:

```bash
oc -n keycloak get secret keycloak-initial-admin \
  -o jsonpath='{.data.username}' | base64 -d && echo
oc -n keycloak get secret keycloak-initial-admin \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

### Create Users

1. Log into the Keycloak admin console
2. Select the **`okd`** realm from the realm dropdown (top-left)
3. Go to **Users** → **Add user**
4. Fill in username, email, first name, last name → **Create**
5. **Credentials** tab → **Set password** → set **Temporary** to **Off** → **Save password**

### Log into OKD via Keycloak

1. Open the OKD console
2. Select **keycloak** (or the value of `KC_IDP_NAME`) as the identity provider
3. You will be redirected to the Keycloak login screen
4. Enter the credentials of a user you created above

Verify OKD created the identity objects:

```bash
oc get user
oc get identity
```

### Grant OKD Roles

New Keycloak users have no OKD permissions by default.

```bash
# Full cluster-admin access
oc adm policy add-cluster-role-to-user cluster-admin <username>

# Cluster-wide read-only
oc adm policy add-cluster-role-to-user view <username>

# Admin access within a specific namespace
oc adm policy add-role-to-user admin <username> -n <namespace>

# Edit access within a specific namespace
oc adm policy add-role-to-user edit <username> -n <namespace>
```

---

## Uninstallation

> ⚠️ **Irreversible.** All Keycloak data — realms, users, sessions — will be permanently deleted. Ensure you have an alternative `cluster-admin` account before proceeding.

```bash
chmod +x uninstall-keycloak-okd.sh
./uninstall-keycloak-okd.sh
```

Skip the confirmation prompt (CI):

```bash
./uninstall-keycloak-okd.sh --yes
```

The script reads `keycloak-config.env` to determine exactly what to remove, so the same config used to install is used to uninstall.

**Removal order:**

| Step | Resource | Notes |
|---|---|---|
| 1 | `keycloak` OAuth identity provider | Only this entry — other providers left intact |
| 1 | `keycloak-client-secret` in `openshift-config` | |
| 2 | `KeycloakRealmImport` CR | |
| 2 | `Keycloak` CR | Waits for pod termination |
| 3 | Route | |
| 4 | Subscription, CSV, OperatorGroup | Removes operator pod |
| 5 | PostgreSQL StatefulSet + Service | All data permanently lost |
| 5 | PersistentVolumeClaim | NFS data on server **not** auto-deleted — see below |
| 6 | Secrets: `keycloak-db-secret`, `keycloak-initial-admin`, `keycloak-client-secret`, `keycloak-tls` | |
| 7 | CRDs | Both Keycloak CRDs cluster-wide |
| 7 | Namespace | Removes any remaining resources |

**After uninstall, clean up NFS data manually** — the PVC deletion releases the binding but the data directory on the NFS server remains:

```bash
# Path depends on your NFS provisioner, typically:
# /exports/<namespace>-postgres-pvc-<uid>/
# Remove this directory on the NFS server.
```

**Verify removal:**

```bash
oc get namespace keycloak
oc get crd | grep keycloak
oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}'
```

---

## Troubleshooting

<details>
<summary><strong>InstallPlan not found or stuck at <code>approved: false</code></strong></summary>

```bash
oc -n keycloak get subscription keycloak-operator -o yaml
oc -n keycloak get installplan

# Approve manually:
oc -n keycloak patch installplan <n> \
  --type merge --patch '{"spec":{"approved":true}}'
```

</details>

<details>
<summary><strong><code>no matches for kind "Keycloak" in version "k8s.keycloak.org/v2alpha1"</code></strong></summary>

The CRDs are not registered yet — the operator CSV has not reached `Succeeded`.

```bash
oc -n keycloak get csv
oc get crd | grep keycloak
```

Wait for the CSV phase to show `Succeeded` before applying `03-keycloak.yaml`.

</details>

<details>
<summary><strong><code>hostname is not configured; either configure hostname, or set hostname-strict to false</code></strong></summary>

Keycloak 26+ requires `hostname.hostname` in the Keycloak CR. The install script handles this automatically. If you applied the CR manually before the Route existed, patch it:

```bash
KEYCLOAK_HOST=$(oc -n keycloak get route keycloak -o jsonpath='{.spec.host}')
oc -n keycloak patch keycloak keycloak --type merge \
  --patch "{\"spec\":{\"hostname\":{\"hostname\":\"${KEYCLOAK_HOST}\"}}}"
```

</details>

<details>
<summary><strong><code>Failed to start server in (production) mode</code></strong></summary>

Check the root cause:

```bash
oc -n keycloak logs deployment/keycloak | grep -A5 'Caused by'
```

| Caused by | Fix |
|---|---|
| `hostname is not configured` | See above |
| `Connection refused` to postgres | Check `postgres-db` Service and `postgresql-db` pod |
| `password authentication failed` | Verify `keycloak-db-secret` matches `DB_USERNAME`/`DB_PASSWORD` in config |
| `OOMKilled` | Increase `KC_MEMORY_LIMIT` in `keycloak-config.env` |

</details>

<details>
<summary><strong><code>metadata.resourceVersion: Invalid value: 0: must be specified for an update</code></strong></summary>

This error occurs when `oc apply` is used directly on the `oauth/cluster` resource. The install script uses `oc patch --type=json` to avoid this. If you see this error, ensure you are running the install script rather than applying `04-realm-and-oauth.yaml` directly.

</details>

<details>
<summary><strong>PVC stuck in <code>Pending</code></strong></summary>

The `DB_STORAGE_CLASS` value in `keycloak-config.env` does not match an available StorageClass, or the NFS provisioner is not running.

```bash
oc get storageclass
oc get pods -A | grep nfs
oc -n keycloak describe pvc postgres-pvc
```

Update `DB_STORAGE_CLASS` to match the correct name and re-run the install.

</details>

<details>
<summary><strong>Keycloak login option not appearing on OKD console</strong></summary>

```bash
# Verify the identity provider was added
oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}'

# Check OAuth pods are running
oc -n openshift-authentication get pods

# Force a rollout
oc -n openshift-authentication rollout restart deployment/oauth-openshift
```

</details>

<details>
<summary><strong>TLS certificate errors in browser (edge or reencrypt mode)</strong></summary>

- Ensure `KC_TLS_CERT` is a **fullchain** certificate including intermediate CA certs
- Verify the certificate SAN matches `KC_HOSTNAME`: `openssl x509 -in $KC_TLS_CERT -noout -text | grep -A1 'Subject Alternative'`
- Check the certificate has not expired: `openssl x509 -in $KC_TLS_CERT -noout -dates`
- For `reencrypt`, verify the pod can serve the cert correctly: `oc -n keycloak logs deployment/keycloak | grep -i tls`

</details>

<details>
<summary><strong>Namespace stuck in <code>Terminating</code></strong></summary>

```bash
# Check what is blocking deletion
oc get namespace keycloak -o yaml

# Force-clear finalizers (last resort)
oc patch namespace keycloak \
  -p '{"metadata":{"finalizers":[]}}' --type=merge
```

After force-removing finalizers, verify no orphaned CRDs remain:

```bash
oc get crd | grep keycloak
```

</details>

---

## OKD vs OCP Differences

This package is built specifically for OKD. The following table summarises the key differences from a standard OpenShift Container Platform (OCP) deployment using the Red Hat SSO Operator.

| Item | OCP (RHSSO) | OKD (this package) |
|---|---|---|
| Operator catalog | `redhat-operators` | `community-operators` |
| Operator name | `rhsso-operator` | `keycloak-operator` |
| OLM channel | `stable` | `fast` |
| CR API group | `keycloak.org/v1alpha1` | `k8s.keycloak.org/v2alpha1` |
| Realm CR | `KeycloakRealm` | `KeycloakRealmImport` |
| Route creation | Automatic via `ingress.enabled` | Manual `Route` resource |
| Issuer URL path | `/auth/realms/<realm>` | `/realms/<realm>` (Keycloak 17+) |
| Bundled database | Included (ephemeral) | Must be provided |
| Hostname required | No | Yes (Keycloak 26+) |
| OAuth update method | `oc apply` | `oc patch --type=json` (resourceVersion issue on cluster singletons) |

---

## Production Checklist

- [ ] Change `DB_PASSWORD` in `keycloak-config.env` to a strong unique password
- [ ] Replace the bundled PostgreSQL `StatefulSet` with a production-grade deployment (managed service, CloudNativePG, or CrunchyData PGO) with replication and automated backups
- [ ] Set `KC_INSTANCES=2` (or more) in `keycloak-config.env` for high availability
- [ ] Use `KC_HOSTNAME_MODE=edge` or `reencrypt` with a valid certificate from a trusted CA
- [ ] Back up the PostgreSQL database before approving any OLM operator upgrade
- [ ] Configure SMTP for password reset: Keycloak admin console → Realm Settings → Email
- [ ] Review token lifespan settings for your security policy (`KC_ACCESS_TOKEN_LIFESPAN`, `KC_SSO_SESSION_MAX`)
- [ ] Monitor NFS PVC usage and set up capacity alerting
- [ ] Confirm an alternative `cluster-admin` account exists that does not use Keycloak
- [ ] Establish an OIDC client secret rotation schedule
- [ ] Assign an owner to the OLM upgrade approval workflow

### Approving Operator Upgrades

> ⚠️ Always back up the PostgreSQL database before approving an upgrade. Keycloak upgrades may run irreversible database migrations.

```bash
# Check for pending upgrades
oc -n keycloak get installplan

# Review release notes:
# https://www.keycloak.org/docs/latest/release_notes/

# Approve
oc -n keycloak patch installplan <n> \
  --type merge --patch '{"spec":{"approved":true}}'
```

---

*© 2026 · OKD Platform Series · Part No. OKD-KC-4-001*
