# LAB AVANCÉ — Sécurité AKS : Key Vault CSI, RBAC avancé & Audit

> Monter des secrets Azure Key Vault comme fichiers dans un pod, implémenter le principe de moindre privilège avec RBAC, et tracer les opérations suspectes via les logs d'audit Kubernetes.
> Durée estimée : 1h30 · Niveau : Avancé

---

## Objectifs

**Partie A — Azure Key Vault CSI Driver : secrets comme fichiers (35 min)**
- Activer le driver CSI Key Vault sur le cluster AKS
- Créer un Key Vault et y stocker des secrets
- Configurer une identité managée avec Workload Identity pour accéder au Key Vault
- Monter plusieurs secrets comme fichiers dans un pod via SecretProviderClass
- Démontrer la rotation automatique des secrets
- Diagnostiquer l'échec d'accès au Key Vault (mauvaise identité)

**Partie B — RBAC avancé : moindre privilège (30 min)**
- Créer un ServiceAccount avec des permissions restreintes
- Définir un Role avec des verbes précis sur des ressources ciblées
- Tester les permissions avec `kubectl auth can-i` et l'impersonation
- Diagnostiquer le refus d'escalade de privilèges

**Partie C — Audit & logging (25 min)**
- Activer les logs de diagnostic AKS (kube-audit)
- Générer des événements auditables (accès refusés, opérations suspectes)
- Interroger les logs d'audit avec des requêtes KQL
- Comprendre l'importance de l'audit dès le jour 1

---

## Contexte

### Gestion des secrets : 3 approches

```
                  Secret K8s natif     Key Vault (env var)   Key Vault CSI (fichier)
                  ─────────────────    ───────────────────   ───────────────────────
Stockage          etcd (base64)        Azure Key Vault       Azure Key Vault
Chiffrement       Optionnel (etcd)     Côté Azure (HSM)      Côté Azure (HSM)
Rotation          Manuelle             Manuelle              Automatique
Accès pod         env var / volume     env var               Fichier monté
Audit             Limité               Azure Activity Log    Azure Activity Log
Recommandé        Dev/test             Simple                Production
```

### Arbre de décision

```
Secret sensible (BDD, clé API, certificat) ?
  │
  ├─ Non → Secret Kubernetes natif (suffisant pour du dev/test)
  │
  └─ Oui → Azure Key Vault
       │
       ├─ L'app lit des env vars → Key Vault + synced Secret K8s
       │
       └─ L'app lit des fichiers → Key Vault CSI Driver (recommandé)
```

### Modèle RBAC Kubernetes

```
Qui ?                    Quoi ?                   Où ?
──────                   ──────                   ────
User / ServiceAccount    Role / ClusterRole       Namespace / Cluster
        │                       │                        │
        └───── RoleBinding ─────┘                        │
               (lie les deux)                             │
               dans un namespace ─────────────────────────┘
```

---

## Prérequis

> Ce lab suppose que le Lab 1 est terminé :
>
> - Cluster AKS avec Workload Identity et OIDC Issuer activés
> - Variables `$RG` et `$CLUSTER_NAME` définies
> - Azure CLI connecté avec les rôles Contributor + Key Vault Administrator
> - `kubectl` configuré

```bash
# Vérifications
kubectl get nodes
az account show --query name -o tsv

# Vérifier que Workload Identity est activé
az aks show -g $RG -n $CLUSTER_NAME \
  --query "{oidcIssuer:oidcIssuerProfile.enabled, workloadIdentity:securityProfile.workloadIdentity.enabled}" \
  -o table
```

**Output attendu :**

```
OidcIssuer    WorkloadIdentity
────────────  ────────────────
True          True
```

> Si `WorkloadIdentity` est `False`, l'activer :
> ```bash
> az aks update -g $RG -n $CLUSTER_NAME --enable-oidc-issuer --enable-workload-identity
> ```

---

## Étape 0 — Variables d'environnement

```bash
# Charger les variables du Lab 1
source ~/.lab1-env
export NAMESPACE_KV="lab-sec-kv"
export NAMESPACE_RBAC="lab-sec-rbac"
export NAMESPACE_AUDIT="lab-sec-audit"
export KV_NAME="kv-aks-lab-${PARTICIPANT_NUM:-1}"
export IDENTITY_NAME="id-kv-lab-${PARTICIPANT_NUM:-1}"
export LOCATION=$(az group show -n $RG --query location -o tsv)

# Vérifier
echo "RG         : $RG"
echo "Cluster    : $CLUSTER_NAME"
echo "Key Vault  : $KV_NAME"
echo "Location   : $LOCATION"
```

```bash
# Créer les namespaces
kubectl create namespace $NAMESPACE_KV
kubectl create namespace $NAMESPACE_RBAC
kubectl create namespace $NAMESPACE_AUDIT
```

---

# PARTIE A — Azure Key Vault CSI Driver : monter les secrets comme fichiers

## Étape 1 — Activer le driver CSI et créer le Key Vault

### 1.1 Activer l'addon Key Vault CSI

```bash
az aks enable-addons \
  --addons azure-keyvault-secrets-provider \
  --name $CLUSTER_NAME \
  --resource-group $RG

# Vérifier que le driver est installé
kubectl get daemonset -n kube-system | grep secrets-store
```

**Output attendu :**

```
aks-secrets-store-csi-driver          1/1   1   1   1   1   <none>   30s
aks-secrets-store-provider-azure      1/1   1   1   1   1   <none>   30s
```

> Deux DaemonSets sont déployés : le driver CSI générique (`secrets-store-csi-driver`) et le provider Azure (`secrets-store-provider-azure`). Ensemble, ils permettent de monter des secrets Key Vault comme fichiers dans un pod.

### 1.2 Créer le Key Vault

```bash
az keyvault create \
  --name $KV_NAME \
  --resource-group $RG \
  --location $LOCATION \
  --enable-rbac-authorization

# Récupérer l'ID du Key Vault
KV_ID=$(az keyvault show --name $KV_NAME --query id -o tsv)
echo "Key Vault ID : $KV_ID"
```

### 1.3 Ajouter des secrets

```bash
# S'assurer d'avoir le rôle Key Vault Administrator
USER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)
az role assignment create \
  --role "Key Vault Administrator" \
  --assignee $USER_OBJECT_ID \
  --scope $KV_ID

# Créer 3 secrets
az keyvault secret set --vault-name $KV_NAME --name db-password --value "S3cureP@ss2025!"
az keyvault secret set --vault-name $KV_NAME --name api-key --value "ak-7f3b9e2d-4a1c-8x5z"
az keyvault secret set --vault-name $KV_NAME --name app-config --value '{"env":"production","debug":false}'

# Vérifier
az keyvault secret list --vault-name $KV_NAME --query "[].name" -o tsv
```

**Output attendu :**

```
api-key
app-config
db-password
```

---

## Étape 2 — Configurer l'identité (Workload Identity)

Le pod doit s'authentifier auprès du Key Vault. On utilise une Managed Identity liée au ServiceAccount Kubernetes via une federated credential.

```
Pod (avec ServiceAccount annoté)
  │
  ▼
Workload Identity → échange le token K8s contre un token Azure AD
  │
  ▼
Managed Identity (avec rôle "Key Vault Secrets User")
  │
  ▼
Azure Key Vault → accès aux secrets
```

### 2.1 Créer la Managed Identity

```bash
az identity create \
  --name $IDENTITY_NAME \
  --resource-group $RG \
  --location $LOCATION

IDENTITY_CLIENT_ID=$(az identity show --name $IDENTITY_NAME -g $RG --query clientId -o tsv)
IDENTITY_OBJECT_ID=$(az identity show --name $IDENTITY_NAME -g $RG --query principalId -o tsv)
echo "Client ID : $IDENTITY_CLIENT_ID"
```

### 2.2 Attribuer le rôle Key Vault Secrets User

```bash
az role assignment create \
  --role "Key Vault Secrets User" \
  --assignee $IDENTITY_OBJECT_ID \
  --scope $KV_ID
```

> Le rôle `Key Vault Secrets User` permet uniquement de **lire** les secrets. L'identité ne peut ni les modifier, ni les supprimer, ni accéder aux clés ou certificats. C'est le principe de moindre privilège.



### 2.3 Créer le ServiceAccount annoté

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: sa-kv-reader
  namespace: $NAMESPACE_KV
  annotations:
    azure.workload.identity/client-id: "$IDENTITY_CLIENT_ID"
EOF
```

---
### 2.4 Créer la federated credential

```bash
AKS_OIDC_ISSUER=$(az aks show -g $RG -n $CLUSTER_NAME --query oidcIssuerProfile.issuerUrl -o tsv)

az identity federated-credential create \
  --name "fc-kv-lab" \
  --identity-name $IDENTITY_NAME \
  --resource-group $RG \
  --issuer $AKS_OIDC_ISSUER \
  --subject "system:serviceaccount:${NAMESPACE_KV}:sa-kv-reader" \
  --audiences "api://AzureADTokenExchange"
```

> La federated credential lie l'identité Azure au ServiceAccount Kubernetes `sa-kv-reader` dans le namespace `lab-sec-kv`. Seul ce SA peut utiliser cette identité.

## Étape 3 — Créer la SecretProviderClass

La SecretProviderClass définit **quels secrets** monter depuis le Key Vault et **comment** y accéder.

```bash
TENANT_ID=$(az account show --query tenantId -o tsv)

cat <<EOF | kubectl apply -f -
apiVersion: secrets-store.csi.x-k8s.io/v1     # API du CSI Secrets Store Driver
kind: SecretProviderClass                     # Type d'objet : configuration de secrets
metadata:
  name: kv-secrets                            # Nom référencé par le pod
  namespace: $NAMESPACE_KV                    # Doit être dans le même namespace que le pod
spec:
  provider: azure                             # Provider = Azure Key Vault
  parameters:
    usePodIdentity: "false"                   # On n'utilise PAS AAD Pod Identity (ancien système)
    useVMManagedIdentity: "false"             # On n'utilise PAS la Managed Identity de la VM
    clientID: "$IDENTITY_CLIENT_ID"           # Client ID de la Managed Identity (via Workload Identity)
    keyvaultName: "$KV_NAME"                  # Nom du Key Vault Azure
    tenantId: "$TENANT_ID"                    # ID du tenant Azure
    objects: |                                # Liste des secrets à monter
      array:            
        - |
          objectName: db-password             # Nom du secret dans Key Vault
          objectType: secret                  # Type : secret (peut être key ou cert)
        - |
          objectName: api-key
          objectType: secret
        - |
          objectName: app-config
          objectType: secret
EOF
```

```bash
kubectl get secretproviderclass -n $NAMESPACE_KV
```

**Output attendu :**

```
NAME         AGE
kv-secrets   10s
```

> Chaque entrée dans `objects` correspond à un fichier qui sera créé dans le volume monté. Le nom du fichier sera le `objectName` du secret.

---

## Étape 4 — Déployer un pod qui monte les secrets

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: secret-reader
  namespace: $NAMESPACE_KV
  labels:
    azure.workload.identity/use: "true"
spec:
  serviceAccountName: sa-kv-reader
  containers:
  - name: app
    image: busybox:latest
    command: ["/bin/sh", "-c", "while true; do sleep 3600; done"]
    volumeMounts:
    - name: secrets
      mountPath: /mnt/secrets
      readOnly: true
    resources:
      requests: { cpu: "25m", memory: "32Mi" }
      limits:   { cpu: "50m", memory: "64Mi" }
  volumes:
  - name: secrets
    csi:
      driver: secrets-store.csi.k8s.io
      readOnly: true
      volumeAttributes:
        secretProviderClass: kv-secrets
EOF
```

```bash
# Attendre que le pod soit Running
kubectl get pod secret-reader -n $NAMESPACE_KV -w
```

> Le label `azure.workload.identity/use: "true"` active l'injection du token Workload Identity dans le pod. Sans ce label, le pod ne pourra pas s'authentifier auprès d'Azure AD.

### 4.1 Vérifier les secrets montés

```bash
# Lister les fichiers dans /mnt/secrets
kubectl exec secret-reader -n $NAMESPACE_KV -- ls -la /mnt/secrets/

# Lire chaque secret
kubectl exec secret-reader -n $NAMESPACE_KV -- cat /mnt/secrets/db-password
kubectl exec secret-reader -n $NAMESPACE_KV -- cat /mnt/secrets/api-key
kubectl exec secret-reader -n $NAMESPACE_KV -- cat /mnt/secrets/app-config
```

**Output attendu :**

```
S3cureP@ss2025!
ak-7f3b9e2d-4a1c-8x5z
{"env":"production","debug":false}
```

> Les secrets sont montés comme des fichiers en lecture seule dans `/mnt/secrets/`. L'application les lit comme n'importe quel fichier — pas besoin de SDK Azure ni de variables d'environnement.

---

## Étape 5 — Rotation automatique des secrets

### 5.1 Activer la rotation

```bash
az aks update \
  --name $CLUSTER_NAME \
  --resource-group $RG \
  --enable-secret-rotation \
  --rotation-poll-interval 1m
```

> Le `rotation-poll-interval` définit l'intervalle auquel le driver CSI vérifie si les secrets ont changé dans le Key Vault. En production, utiliser `2h` ou `4h` pour limiter les appels API. Ici, `1m` pour voir le résultat rapidement.

### 5.2 Modifier un secret dans le Key Vault

```bash
# Mettre à jour le mot de passe
az keyvault secret set --vault-name $KV_NAME --name db-password --value "N3wP@ssw0rd2026!"

# Vérifier la nouvelle valeur côté Azure
az keyvault secret show --vault-name $KV_NAME --name db-password --query value -o tsv
```

### 5.3 Vérifier la rotation dans le pod

```bash
# Attendre 1-2 min (le poll interval est de 1 min)
sleep 90

# Lire le secret mis à jour
kubectl exec secret-reader -n $NAMESPACE_KV -- cat /mnt/secrets/db-password
```

**Output attendu :**

```
N3wP@ssw0rd2026!
```

> Le pod voit automatiquement la nouvelle valeur **sans redémarrage**. Le driver CSI a détecté le changement dans le Key Vault et a mis à jour le fichier monté.

---

## Étape 6 — Test de rupture : mauvais ServiceAccount

Que se passe-t-il si un pod utilise un ServiceAccount sans federated credential ?

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: secret-thief
  namespace: $NAMESPACE_KV
  labels:
    azure.workload.identity/use: "true"
spec:
  serviceAccountName: default
  containers:
  - name: app
    image: busybox:latest
    command: ["/bin/sh", "-c", "while true; do sleep 3600; done"]
    volumeMounts:
    - name: secrets
      mountPath: /mnt/secrets
      readOnly: true
    resources:
      requests: { cpu: "25m", memory: "32Mi" }
      limits:   { cpu: "50m", memory: "64Mi" }
  volumes:
  - name: secrets
    csi:
      driver: secrets-store.csi.k8s.io
      readOnly: true
      volumeAttributes:
        secretProviderClass: kv-secrets
EOF

# Observer l'état du pod
kubectl get pod secret-thief -n $NAMESPACE_KV -w
```

Après 30-60 secondes :

```bash
kubectl describe pod secret-thief -n $NAMESPACE_KV | tail -15
```

**Output attendu :**

```
Events:
  Warning  FailedMount  ...  MountVolume.SetUp failed for volume "secrets" :
  rpc error: ... failed to get keyvault client: ... AADSTS700213:
  No matching federated identity record found for presented assertion
```

> **Diagnostic :** le ServiceAccount `default` n'a pas de federated credential associée. Le driver CSI ne peut pas obtenir de token Azure AD et le montage échoue. Seul le SA `sa-kv-reader` (avec la federated credential configurée à l'étape 2) peut accéder au Key Vault.
>
> **Leçon :** même si un attaquant parvient à déployer un pod dans le namespace, il ne peut pas accéder aux secrets du Key Vault sans le bon ServiceAccount.

```bash
# Nettoyer
kubectl delete pod secret-thief -n $NAMESPACE_KV
```

---

# PARTIE B — RBAC avancé : moindre privilège

> **Avant de commencer :** sur un nœud B2s, supprimer le pod de la partie A si nécessaire :
>
> ```bash
> kubectl delete pod secret-reader -n $NAMESPACE_KV
> ```

## Étape 7 — Créer un ServiceAccount restreint

```bash
kubectl create serviceaccount dev-deployer -n $NAMESPACE_RBAC
```

```bash
# Vérifier
kubectl get serviceaccount dev-deployer -n $NAMESPACE_RBAC
```

**Output attendu :**

```
NAME            SECRETS   AGE
dev-deployer    0         5s
```

> Par défaut, un ServiceAccount n'a **aucune permission** (RBAC activé par défaut sur AKS). Il ne peut ni lire les pods, ni créer de ressources, ni accéder aux secrets.

---

## Étape 8 — Créer un Role avec privilèges minimaux

```bash
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: deployer-role
  namespace: $NAMESPACE_RBAC
rules:
# Peut gérer les pods (déployer, lister, supprimer)
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch", "create", "delete"]
# Peut lire les services (mais pas les créer/modifier)
- apiGroups: [""]
  resources: ["services"]
  verbs: ["get", "list"]
# Peut lire les logs des pods
- apiGroups: [""]
  resources: ["pods/log"]
  verbs: ["get"]
EOF
```

> Chaque règle définit un triplet `apiGroups` / `resources` / `verbs`. Le `""` dans apiGroups représente le core API group (pods, services, secrets, etc.).
>
> | Verbe | Signification |
> |-------|---------------|
> | `get` | Lire une ressource spécifique par nom |
> | `list` | Lister toutes les ressources du type |
> | `watch` | Recevoir les mises à jour en temps réel |
> | `create` | Créer une nouvelle ressource |
> | `delete` | Supprimer une ressource existante |
> | `update` | Modifier une ressource existante |
> | `patch` | Modifier partiellement une ressource |

---

## Étape 9 — Créer le RoleBinding

```bash
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: deployer-binding
  namespace: $NAMESPACE_RBAC
subjects:
- kind: ServiceAccount
  name: dev-deployer
  namespace: $NAMESPACE_RBAC
roleRef:
  kind: Role
  name: deployer-role
  apiGroup: rbac.authorization.k8s.io
EOF
```

```bash
kubectl get role,rolebinding -n $NAMESPACE_RBAC
```

**Output attendu :**

```
NAME                                        CREATED AT
role.rbac.authorization.k8s.io/deployer-role   2026-05-21T...

NAME                                                  ROLE                AGE
rolebinding.rbac.authorization.k8s.io/deployer-binding   Role/deployer-role   5s
```

---

## Étape 10 — Tester les permissions avec `kubectl auth can-i`

```bash
SA="system:serviceaccount:${NAMESPACE_RBAC}:dev-deployer"

# Actions autorisées
kubectl auth can-i list pods --as=$SA -n $NAMESPACE_RBAC
kubectl auth can-i create pods --as=$SA -n $NAMESPACE_RBAC
kubectl auth can-i get services --as=$SA -n $NAMESPACE_RBAC
kubectl auth can-i get pods/log --as=$SA -n $NAMESPACE_RBAC

# Actions refusées
kubectl auth can-i create deployments --as=$SA -n $NAMESPACE_RBAC
kubectl auth can-i delete services --as=$SA -n $NAMESPACE_RBAC
kubectl auth can-i get secrets --as=$SA -n $NAMESPACE_RBAC
kubectl auth can-i create namespaces --as=$SA
```

**Output attendu :**

```
yes
yes
yes
yes
no
no
no
no
```

> Résumé des permissions :
>
> | Action | Autorisé | Raison |
> |--------|----------|--------|
> | list pods | Oui | Règle explicite dans le Role |
> | create pods | Oui | Règle explicite dans le Role |
> | get services | Oui | Règle explicite (lecture seule) |
> | get pods/log | Oui | Règle explicite |
> | create deployments | Non | Pas dans le Role |
> | delete services | Non | Seuls get/list sont autorisés |
> | get secrets | Non | Pas dans le Role |
> | create namespaces | Non | Pas de ClusterRoleBinding |

---

## Étape 11 — Impersonation : agir en tant que le ServiceAccount

```bash
SA="system:serviceaccount:${NAMESPACE_RBAC}:dev-deployer"

# Créer un pod en tant que dev-deployer (autorisé)
kubectl --as=$SA run test-pod --image=nginx:alpine -n $NAMESPACE_RBAC \
  --override-type=strategic \
  --overrides='{"spec":{"containers":[{"name":"test-pod","image":"nginx:alpine","resources":{"requests":{"cpu":"25m","memory":"32Mi"},"limits":{"cpu":"50m","memory":"64Mi"}}}]}}'

# Vérifier (autorisé)
kubectl --as=$SA get pods -n $NAMESPACE_RBAC
```

**Output attendu :**

```
NAME       READY   STATUS    RESTARTS   AGE
test-pod   1/1     Running   0          10s
```

```bash
# Tenter de créer un deployment (refusé)
kubectl --as=$SA create deployment nginx-deploy --image=nginx:alpine -n $NAMESPACE_RBAC
```

**Output attendu :**

```
error: failed to create deployment: deployments.apps is forbidden:
User "system:serviceaccount:lab-sec-rbac:dev-deployer" cannot create
resource "deployments" in API group "apps" in the namespace "lab-sec-rbac"
```

```bash
# Tenter de lire les secrets (refusé)
kubectl --as=$SA get secrets -n $NAMESPACE_RBAC
```

**Output attendu :**

```
Error from server (Forbidden): secrets is forbidden:
User "system:serviceaccount:lab-sec-rbac:dev-deployer" cannot list
resource "secrets" in API group "" in the namespace "lab-sec-rbac"
```

> L'impersonation (`--as=`) permet de tester exactement ce que le ServiceAccount peut faire, sans avoir à créer un pod avec ce SA. C'est l'outil essentiel pour valider les politiques RBAC avant de les déployer en production.

```bash
# Nettoyer le pod de test
kubectl --as=$SA delete pod test-pod -n $NAMESPACE_RBAC
```

---

## Étape 12 — Test de rupture : tentative d'escalade de privilèges

Que se passe-t-il si le ServiceAccount `dev-deployer` tente de se donner les droits `cluster-admin` ?

```bash
SA="system:serviceaccount:${NAMESPACE_RBAC}:dev-deployer"

# Tenter de créer un RoleBinding vers cluster-admin
kubectl --as=$SA create rolebinding escalation \
  --clusterrole=cluster-admin \
  --serviceaccount=${NAMESPACE_RBAC}:dev-deployer \
  -n $NAMESPACE_RBAC
```

**Output attendu :**

```
error: failed to create rolebinding: rolebindings.rbac.authorization.k8s.io is forbidden:
User "system:serviceaccount:lab-sec-rbac:dev-deployer" cannot create
resource "rolebindings" in API group "rbac.authorization.k8s.io"
in the namespace "lab-sec-rbac"
```

```bash
# Tenter d'accéder à un autre namespace
kubectl --as=$SA get pods -n kube-system
```

**Output attendu :**

```
Error from server (Forbidden): pods is forbidden:
User "system:serviceaccount:lab-sec-rbac:dev-deployer" cannot list
resource "pods" in API group "" in the namespace "kube-system"
```

> **Diagnostic :** Kubernetes RBAC empêche l'escalade de privilèges de deux manières :
>
> 1. **Pas de permission sur les RoleBindings** → le SA ne peut pas créer de bindings
> 2. **Scope limité au namespace** → le SA n'a aucun droit en dehors de `lab-sec-rbac`
>
> Même si un attaquant compromet un pod avec ce SA, il ne peut ni lire les secrets, ni accéder aux autres namespaces, ni s'accorder plus de droits.

---

# PARTIE C — Audit & logging : tracer les opérations suspectes

> **Avant de commencer :** cette partie utilise Azure Monitor et Log Analytics. Les logs peuvent prendre 5-15 minutes pour apparaître dans Log Analytics après les opérations.

## Étape 13 — Activer les logs de diagnostic AKS

### 13.1 Créer un workspace Log Analytics

```bash
WORKSPACE_NAME="law-aks-lab-${PARTICIPANT_NUM:-1}"

az monitor log-analytics workspace create \
  --resource-group $RG \
  --workspace-name $WORKSPACE_NAME \
  --location $LOCATION

WORKSPACE_ID=$(az monitor log-analytics workspace show \
  --resource-group $RG \
  --workspace-name $WORKSPACE_NAME \
  --query id -o tsv)
echo "Workspace ID : $WORKSPACE_ID"
```

### 13.2 Activer les diagnostic settings

```bash
CLUSTER_ID=$(az aks show -g $RG -n $CLUSTER_NAME --query id -o tsv)

az monitor diagnostic-settings create \
  --name "aks-audit-logs" \
  --resource $CLUSTER_ID \
  --workspace $WORKSPACE_ID \
  --logs '[
    {"category": "kube-audit-admin", "enabled": true},
    {"category": "kube-audit", "enabled": true},
    {"category": "guard", "enabled": true}
  ]'
```

```bash
# Vérifier
az monitor diagnostic-settings show \
  --name "aks-audit-logs" \
  --resource $CLUSTER_ID \
  --query "logs[].{Catégorie:category, Activé:enabled}" -o table
```

**Output attendu :**

```
Catégorie          Activé
─────────────────  ──────
kube-audit-admin   True
kube-audit         True
guard              True
```

> | Catégorie | Ce qu'elle capture |
> |-----------|-------------------|
> | `kube-audit-admin` | Opérations d'écriture (create, update, delete, patch) — allégé |
> | `kube-audit` | Toutes les opérations (lecture + écriture) — complet mais volumineux |
> | `guard` | Décisions d'autorisation Azure AD (connexions, refus) |

---

## Étape 14 — Générer des événements auditables

```bash
SA="system:serviceaccount:${NAMESPACE_RBAC}:dev-deployer"

# Opération normale (autorisée)
kubectl run audit-pod --image=nginx:alpine -n $NAMESPACE_AUDIT \
  --overrides='{"spec":{"containers":[{"name":"audit-pod","image":"nginx:alpine","resources":{"requests":{"cpu":"25m","memory":"32Mi"},"limits":{"cpu":"50m","memory":"64Mi"}}}]}}'

# Opération suspecte : accès aux secrets (refusée)
kubectl --as=$SA get secrets -n $NAMESPACE_AUDIT 2>/dev/null || true

# Opération suspecte : accès au namespace système (refusée)
kubectl --as=$SA get pods -n kube-system 2>/dev/null || true

# Opération suspecte : tentative de suppression namespace (refusée)
kubectl --as=$SA delete namespace $NAMESPACE_AUDIT 2>/dev/null || true

echo "Événements générés. Les logs apparaîtront dans Log Analytics dans 5-15 minutes."
```

```bash
# Nettoyer le pod de test
kubectl delete pod audit-pod -n $NAMESPACE_AUDIT
```

---

## Étape 15 — Interroger les logs d'audit

> **Attendre 5-15 minutes** après l'étape 14 pour que les logs arrivent dans Log Analytics.

### 15.1 Requête KQL : opérations refusées (403 Forbidden)

```bash
az monitor log-analytics query \
  --workspace $WORKSPACE_ID \
  --analytics-query '
AzureDiagnostics
| where Category == "kube-audit"
| where ResultType has "Failure" or log_s has "Forbidden"
| project TimeGenerated, user_username_s, verb_s, resource_s, namespace_s, ResponseStatus_code_d
| order by TimeGenerated desc
| take 20
' \
  --output table
```

**Output attendu (après le délai) :**

```
TimeGenerated             user_username_s                                    verb_s  resource_s  namespace_s   ResponseStatus_code_d
────────────────────────  ─────────────────────────────────────────────────   ──────  ──────────  ────────────  ─────────────────────
2026-05-21T01:15:32Z      system:serviceaccount:lab-sec-rbac:dev-deployer    list    secrets     lab-sec-audit 403
2026-05-21T01:15:33Z      system:serviceaccount:lab-sec-rbac:dev-deployer    list    pods        kube-system   403
2026-05-21T01:15:34Z      system:serviceaccount:lab-sec-rbac:dev-deployer    delete  namespaces  lab-sec-audit 403
```

### 15.2 Requête KQL : qui accède aux secrets ?

```bash
az monitor log-analytics query \
  --workspace $WORKSPACE_ID \
  --analytics-query '
AzureDiagnostics
| where Category == "kube-audit"
| where resource_s == "secrets"
| project TimeGenerated, user_username_s, verb_s, namespace_s, ResponseStatus_code_d
| order by TimeGenerated desc
| take 10
' \
  --output table
```

> Ces requêtes permettent de détecter :
> - **Qui** a tenté d'accéder à des ressources sensibles (secrets, namespaces système)
> - **Quand** l'accès a eu lieu
> - **Si** l'accès a été autorisé (200) ou refusé (403)
>
> En production, créer des alertes Azure Monitor sur ces requêtes pour être notifié en temps réel des tentatives suspectes.

---

## Étape 16 — Test de rupture : cluster sans audit

> Cette étape est **conceptuelle** — on ne désactive pas les logs qu'on vient d'activer.

Sans les diagnostic settings, voici ce qui se passe :

```
Scénario : un pod compromis tente de lire des secrets

  Avec audit activé :
    → L'opération est enregistrée dans Log Analytics
    → Une alerte est déclenchée
    → L'équipe sécurité investigue dans les minutes qui suivent
    → La source de la compromission est identifiée

  Sans audit :
    → Aucune trace de l'opération
    → Personne n'est alerté
    → La compromission reste invisible pendant des jours/semaines
    → Pas de forensics possible
```

> **Bonne pratique :** activer les diagnostic settings (au minimum `kube-audit-admin`) dès la création du cluster, **avant** le premier déploiement. Les logs sont la seule source de vérité pour l'investigation post-incident.
>
> **Coût :** les logs `kube-audit` (complet) peuvent générer un volume important. En production, utiliser `kube-audit-admin` (opérations d'écriture uniquement) pour réduire les coûts tout en gardant la visibilité sur les modifications.

---

## Nettoyage des ressources

```bash
# Supprimer les namespaces (supprime les pods, SA, Roles, RoleBindings)
kubectl delete namespace $NAMESPACE_KV
kubectl delete namespace $NAMESPACE_RBAC
kubectl delete namespace $NAMESPACE_AUDIT

# Supprimer le Key Vault
az keyvault delete --name $KV_NAME --resource-group $RG
az keyvault purge --name $KV_NAME --location $LOCATION 2>/dev/null || true

# Supprimer la Managed Identity
az identity delete --name $IDENTITY_NAME --resource-group $RG

# Supprimer les diagnostic settings
CLUSTER_ID=$(az aks show -g $RG -n $CLUSTER_NAME --query id -o tsv)
az monitor diagnostic-settings delete --name "aks-audit-logs" --resource $CLUSTER_ID

# Supprimer le workspace Log Analytics (optionnel — peut servir pour d'autres labs)
# az monitor log-analytics workspace delete --resource-group $RG --workspace-name $WORKSPACE_NAME --yes

# Vérifier
kubectl get namespaces | grep lab-sec
az keyvault list -g $RG --query "[].name" -o tsv
```

> La suppression des namespaces supprime automatiquement les Roles, RoleBindings, ServiceAccounts et pods associés. Le `az keyvault purge` est nécessaire car les Key Vaults supprimés restent en "soft-delete" pendant 90 jours.

---

## Récapitulatif des concepts vus

| Concept | Ce que vous avez fait |
|---|---|
| Key Vault CSI Driver | Monter des secrets Azure Key Vault comme fichiers dans un pod |
| SecretProviderClass | Définir quels secrets monter et comment s'authentifier |
| Workload Identity | Lier un ServiceAccount K8s à une Managed Identity Azure |
| Federated Credential | Autoriser un SA spécifique à utiliser une identité Azure |
| Rotation automatique | Le driver CSI détecte les changements dans le Key Vault |
| Role / RoleBinding | Définir des permissions granulaires dans un namespace |
| Moindre privilège | Accorder uniquement les verbes nécessaires sur les ressources nécessaires |
| `kubectl auth can-i` | Vérifier les permissions d'un SA avant de déployer |
| Impersonation (`--as`) | Agir en tant qu'un SA pour tester ses droits réels |
| Diagnostic settings | Envoyer les logs d'audit K8s vers Log Analytics |
| Requêtes KQL | Détecter les accès refusés et les opérations suspectes |

---

## Questions de vérification

1. Pourquoi le driver CSI Key Vault est-il préféré aux Secrets Kubernetes natifs pour les données sensibles en production ? Citez 3 avantages.
2. Un pod avec le label `azure.workload.identity/use: "true"` mais sans le bon ServiceAccount peut-il accéder au Key Vault ? Pourquoi ?
3. Quelle est la différence entre un `Role` et un `ClusterRole` ? Dans quel cas utiliser l'un ou l'autre ?
4. Un développeur a besoin de lire les logs des pods et de créer des deployments dans un namespace. Rédigez le Role minimal correspondant.
5. Les logs `kube-audit` affichent un code `403` pour un ServiceAccount inconnu à 3h du matin. Quelles actions prendre ?
6. Pourquoi la rotation automatique des secrets est-elle importante ? Que se passe-t-il si un secret est compromis sans rotation ?

---

## Pour aller plus loin

- **Azure Policy pour AKS** : appliquer des contraintes au niveau du cluster (interdire les images non signées, forcer les `resources.requests`, bloquer les `privileged: true`). Remplace OPA Gatekeeper avec une intégration Azure native.
- **Pod Security Standards (PSS)** : les 3 niveaux `privileged`, `baseline`, `restricted` de Kubernetes. Appliquer via les labels de namespace (`pod-security.kubernetes.io/enforce: restricted`).
- **Workload Identity Federation** : utiliser Workload Identity pour accéder à d'autres services Azure (Storage Account, Azure SQL, Cosmos DB) — même pattern que le Key Vault.
- **Microsoft Defender for Containers** : détection des menaces en temps réel (images vulnérables, comportements suspects, exfiltration de données). Intégré au portail Azure Security Center.
- **Falco** : outil open-source de détection d'anomalies runtime. Détecte les shell inversés, les lectures de `/etc/shadow`, les modifications de binaires système dans les conteneurs.
