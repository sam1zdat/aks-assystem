# LAB AVANCÉ — Service Mesh & mTLS : Network Policies + Istio

> Segmenter le réseau Kubernetes avec les Network Policies (micro-segmentation L3/L4), puis comprendre le chiffrement inter-services avec Istio et le mTLS (L7).
> Durée estimée : 1h20 · Niveau : Avancé

---

## Objectifs

**Partie A — Network Policies pratiques : micro-segmentation (50 min)**
- Déployer une architecture microservices (frontend, backend, database)
- Prouver que le réseau Kubernetes est ouvert par défaut (attaque latérale)
- Appliquer une politique default-deny totale
- Autoriser uniquement les flux légitimes (principe de moindre privilège réseau)
- Valider la segmentation avec une matrice de tests positifs et négatifs
- Diagnostiquer les échecs courants (DNS, label spoofing)

**Partie B — Istio & mTLS : architecture et manifestes (30 min)**
- Comprendre l'architecture Istio (control plane, data plane, sidecar)
- Étudier les manifestes PeerAuthentication (modes STRICT/PERMISSIVE)
- Étudier les DestinationRules et le mode TLS client
- Comprendre les identités SPIFFE et les certificats X.509
- Comparer Network Policies (labels) vs Istio (identité cryptographique)

> **Note :** Istio nécessite ~1 vCPU + 1.5 Gi RAM pour `istiod` seul. Sur un nœud B2s (2 vCPU, 4 Gi total), il ne reste pas assez de ressources. La Partie B est donc **explicative** : on étudie les manifestes et concepts sans les déployer.

---

## Contexte

### Pourquoi segmenter le réseau Kubernetes ?

Par défaut, **tous les pods peuvent communiquer avec tous les autres pods** dans le cluster, quel que soit le namespace :

```
Par défaut (réseau plat) :

  namespace: frontend        namespace: backend         namespace: database
  ┌──────────┐              ┌──────────┐              ┌──────────┐
  │  pod-web │──────────────│ pod-api  │──────────────│ pod-db   │
  └──────────┘              └──────────┘              └──────────┘
       │                                                    ▲
       │         namespace: attacker                        │
       │         ┌──────────┐                              │
       └─────────│ pod-hack │──────────────────────────────┘
                 └──────────┘
                 L'attaquant accède directement à la BDD !
```

### Deux couches complémentaires de sécurité réseau

```
                    Network Policies         Istio mTLS
                    ────────────────         ──────────
Couche              L3/L4 (IP, port)         L7 (HTTP, gRPC)
Identité            Labels Kubernetes        Certificat X.509 (SPIFFE)
Chiffrement         Non                      Oui (TLS mutuel)
Granularité         Pod-to-pod               Service-to-service
Authentification    Non (labels usurpables)  Oui (cryptographique)
Performances        Zéro overhead            ~2ms latence (proxy Envoy)
Prérequis           CNI compatible           Istio installé (~1.5 Gi RAM)
```

### Architecture du lab (Partie A)

```
                    ┌─────────────────────────────────────┐
                    │  Namespace: lab-netpol               │
                    │                                      │
  Entrée externe ──▶│  frontend ──▶ backend ──▶ database  │
                    │      (80)       (8080)      (5432)   │
                    │                                      │
                    │  attacker (pod de test)              │
                    └─────────────────────────────────────┘

  Objectif : seuls les flux frontend→backend et backend→database
             sont autorisés. L'attacker ne peut rien atteindre.
```

---

## Prérequis

> Ce lab suppose que le Lab 1 est terminé :
>
> - Cluster AKS opérationnel
> - Variables `$RG` et `$CLUSTER_NAME` définies
> - Azure CNI activé (nécessaire pour les Network Policies)

```bash
# Vérifier le plugin réseau
az aks show -g $RG -n $CLUSTER_NAME --query "networkProfile.networkPlugin" -o tsv
```

**Output attendu :**

```
azure
```

> Si le résultat est `kubenet`, les Network Policies ne fonctionneront pas par défaut. Il faut soit recréer le cluster avec `--network-plugin azure`, soit activer Calico : `--network-policy calico`.

```bash
# Vérifier que le cluster est opérationnel
kubectl get nodes
```

---

## Étape 0 — Variables et préparation

```bash
# Charger les variables du Lab 1
source ~/.lab1-env
export NAMESPACE="lab-netpol"

# Vérifier
echo "RG       : $RG"
echo "Cluster  : $CLUSTER_NAME"
echo "Namespace: $NAMESPACE"
```

```bash
# Créer le namespace
kubectl create namespace $NAMESPACE
```

---

# PARTIE A — Network Policies pratiques : micro-segmentation

## Étape 1 — Déployer les microservices de test

### 1.1 Service "frontend"

```bash
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
        tier: web
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
        resources:
          requests: { cpu: "25m", memory: "32Mi" }
          limits:   { cpu: "50m", memory: "64Mi" }
---
apiVersion: v1
kind: Service
metadata:
  name: frontend
  namespace: $NAMESPACE
spec:
  selector:
    app: frontend
  ports:
  - port: 80
    targetPort: 80
EOF
```

### 1.2 Service "backend"

```bash
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
        tier: api
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
        resources:
          requests: { cpu: "25m", memory: "32Mi" }
          limits:   { cpu: "50m", memory: "64Mi" }
---
apiVersion: v1
kind: Service
metadata:
  name: backend
  namespace: $NAMESPACE
spec:
  selector:
    app: backend
  ports:
  - port: 8080
    targetPort: 80
EOF
```

### 1.3 Service "database"

```bash
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: database
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: database
  template:
    metadata:
      labels:
        app: database
        tier: data
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
        resources:
          requests: { cpu: "25m", memory: "32Mi" }
          limits:   { cpu: "50m", memory: "64Mi" }
---
apiVersion: v1
kind: Service
metadata:
  name: database
  namespace: $NAMESPACE
spec:
  selector:
    app: database
  ports:
  - port: 5432
    targetPort: 80
EOF
```

### 1.4 Pod "attacker"

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: attacker
  namespace: $NAMESPACE
  labels:
    app: attacker
    tier: malicious
spec:
  containers:
  - name: curl
    image: curlimages/curl:latest
    command: ["/bin/sh", "-c", "sleep 3600"]
    resources:
      requests: { cpu: "25m", memory: "32Mi" }
      limits:   { cpu: "50m", memory: "64Mi" }
EOF
```

### 1.5 Vérification

```bash
kubectl get pods,svc -n $NAMESPACE
```

**Output attendu :**

```
NAME                            READY   STATUS    RESTARTS   AGE
pod/attacker                    1/1     Running   0          10s
pod/backend-xxxxxxxxx-xxxxx     1/1     Running   0          10s
pod/database-xxxxxxxxx-xxxxx    1/1     Running   0          10s
pod/frontend-xxxxxxxxx-xxxxx    1/1     Running   0          10s

NAME               TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)
service/backend    ClusterIP   10.0.x.x        <none>        8080/TCP
service/database   ClusterIP   10.0.x.x        <none>        5432/TCP
service/frontend   ClusterIP   10.0.x.x        <none>        80/TCP
```

---

## Étape 2 — Prouver que le réseau est ouvert par défaut

```bash
# L'attacker peut accéder au backend
kubectl exec attacker -n $NAMESPACE -- curl -s --max-time 3 http://backend:8080
echo "---"

# L'attacker peut accéder DIRECTEMENT à la database (dangereux !)
kubectl exec attacker -n $NAMESPACE -- curl -s --max-time 3 http://database:5432
echo "---"

# Le frontend peut accéder à la database (bypass du backend)
FRONTEND_POD=$(kubectl get pod -n $NAMESPACE -l app=frontend -o jsonpath='{.items[0].metadata.name}')
kubectl exec $FRONTEND_POD -n $NAMESPACE -- wget -qO- --timeout=3 http://database:5432
```

**Output attendu :**

```
<!DOCTYPE html>
<html>
<head><title>Welcome to nginx!</title>...
---
<!DOCTYPE html>
<html>
<head><title>Welcome to nginx!</title>...
---
<!DOCTYPE html>
<html>
<head><title>Welcome to nginx!</title>...
```

> **Problème de sécurité démontré :**
> - L'attacker accède directement à la "base de données" sans passer par le backend
> - Le frontend peut court-circuiter le backend et accéder à la database
> - N'importe quel pod compromis peut scanner tout le réseau interne
>
> C'est le comportement par défaut de Kubernetes — le réseau est **plat et ouvert**.

---

## Étape 3 — Appliquer la politique default-deny

```bash
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: $NAMESPACE
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF
```

> `podSelector: {}` = s'applique à **tous** les pods du namespace. Avec `Ingress` et `Egress` dans `policyTypes` sans aucune règle → tout le trafic entrant ET sortant est bloqué.
>
> C'est l'équivalent réseau d'un "deny all" en firewall. À partir de maintenant, on autorise uniquement ce qui est explicitement nécessaire.

---

## Étape 4 — Vérifier que TOUT est bloqué

```bash
# L'attacker ne peut plus accéder au backend (timeout)
kubectl exec attacker -n $NAMESPACE -- curl -s --max-time 3 http://backend:8080
echo "Exit code: $?"

# Le frontend ne peut plus accéder au backend (même le trafic légitime !)
kubectl exec $FRONTEND_POD -n $NAMESPACE -- wget -qO- --timeout=3 http://backend:8080
echo "Exit code: $?"

# L'attacker ne peut plus accéder à la database
kubectl exec attacker -n $NAMESPACE -- curl -s --max-time 3 http://database:5432
echo "Exit code: $?"
```

**Output attendu :**

```
curl: (28) Connection timed out after 3001 milliseconds
Exit code: 28

wget: download timed out
Exit code: 1

curl: (28) Connection timed out after 3001 milliseconds
Exit code: 28
```

> Tout est bloqué — y compris le trafic légitime frontend→backend. C'est normal : on a appliqué un deny-all, il faut maintenant autoriser les flux nécessaires un par un.

---

## Étape 5 — Autoriser les flux légitimes uniquement

### 5.1 Autoriser la résolution DNS (indispensable)

```bash
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: $NAMESPACE
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector: {}
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
EOF
```

> **Pourquoi DNS en premier ?** Sans résolution DNS, les pods ne peuvent pas résoudre les noms de services (`backend`, `database`). Les connexions échouent avec `can't resolve host` au lieu de `timeout`. Le DNS est toujours la première règle à autoriser après un default-deny.

### 5.2 Autoriser frontend → backend

```bash
cat <<EOF | kubectl apply -f -
# Egress : le frontend peut envoyer vers le backend sur le port 8080
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: frontend-to-backend-egress
  namespace: $NAMESPACE
spec:
  podSelector:
    matchLabels:
      app: frontend
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: backend
    ports:
    - protocol: TCP
      port: 80
---
# Ingress : le backend accepte le trafic du frontend
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-from-frontend-ingress
  namespace: $NAMESPACE
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 80
EOF
```

> Les Network Policies sont **additives** : chaque nouvelle policy ajoute des règles, elle ne remplace pas les précédentes. Il faut autoriser **les deux côtés** : l'egress du source ET l'ingress de la destination.

### 5.3 Autoriser backend → database

```bash
cat <<EOF | kubectl apply -f -
# Egress : le backend peut envoyer vers la database sur le port 80
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-to-database-egress
  namespace: $NAMESPACE
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: database
    ports:
    - protocol: TCP
      port: 80
---
# Ingress : la database accepte le trafic du backend uniquement
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: database-from-backend-ingress
  namespace: $NAMESPACE
spec:
  podSelector:
    matchLabels:
      app: database
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: backend
    ports:
    - protocol: TCP
      port: 80
EOF
```

---

## Étape 6 — Valider la micro-segmentation

### 6.1 Tests positifs (doivent réussir)

```bash
# frontend → backend (autorisé)
kubectl exec $FRONTEND_POD -n $NAMESPACE -- wget -qO- --timeout=3 http://backend:8080
echo "--- frontend→backend : OK"

# backend → database (autorisé)
BACKEND_POD=$(kubectl get pod -n $NAMESPACE -l app=backend -o jsonpath='{.items[0].metadata.name}')
kubectl exec $BACKEND_POD -n $NAMESPACE -- wget -qO- --timeout=3 http://database:5432
echo "--- backend→database : OK"
```

### 6.2 Tests négatifs (doivent échouer)

```bash
# attacker → backend (bloqué)
kubectl exec attacker -n $NAMESPACE -- curl -s --max-time 3 http://backend:8080
echo "--- attacker→backend : BLOQUÉ (exit $?)"

# attacker → database (bloqué)
kubectl exec attacker -n $NAMESPACE -- curl -s --max-time 3 http://database:5432
echo "--- attacker→database : BLOQUÉ (exit $?)"

# frontend → database directement (bloqué — pas de bypass)
kubectl exec $FRONTEND_POD -n $NAMESPACE -- wget -qO- --timeout=3 http://database:5432
echo "--- frontend→database : BLOQUÉ (exit $?)"

# backend → frontend (bloqué — flux inverse non autorisé)
kubectl exec $BACKEND_POD -n $NAMESPACE -- wget -qO- --timeout=3 http://frontend:80
echo "--- backend→frontend : BLOQUÉ (exit $?)"
```

### 6.3 Matrice d'accès

| Source | Destination | Résultat | Politique qui contrôle |
|--------|-------------|----------|----------------------|
| frontend | backend:8080 | Autorisé | `frontend-to-backend-egress` + `backend-from-frontend-ingress` |
| backend | database:5432 | Autorisé | `backend-to-database-egress` + `database-from-backend-ingress` |
| attacker | backend | Bloqué | `default-deny-all` (pas de règle pour attacker) |
| attacker | database | Bloqué | `default-deny-all` |
| frontend | database | Bloqué | Pas d'egress frontend→database |
| backend | frontend | Bloqué | Pas d'egress backend→frontend |

---

## Étape 7 — Test de rupture : pod imposteur (label spoofing)

Que se passe-t-il si un pod malveillant utilise le label `app: frontend` ?

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: impostor
  namespace: $NAMESPACE
  labels:
    app: frontend
    tier: malicious
spec:
  containers:
  - name: curl
    image: curlimages/curl:latest
    command: ["/bin/sh", "-c", "sleep 3600"]
    resources:
      requests: { cpu: "25m", memory: "32Mi" }
      limits:   { cpu: "50m", memory: "64Mi" }
EOF

# Attendre que le pod soit Running
kubectl get pod impostor -n $NAMESPACE -w
```

```bash
# L'imposteur peut-il accéder au backend ?
kubectl exec impostor -n $NAMESPACE -- curl -s --max-time 3 http://backend:8080
```

**Output attendu :**

```
<!DOCTYPE html>
<html>
<head><title>Welcome to nginx!</title>...
```

> **Le pod imposteur accède au backend !** Parce que les Network Policies ne vérifient que les **labels** — elles ne valident pas l'identité cryptographique du pod. N'importe quel pod avec le label `app: frontend` est autorisé.
>
> **C'est la limitation fondamentale des Network Policies :**
> - Sécurité basée sur des labels (déclaratifs, usurpables)
> - Pas de chiffrement du trafic
> - Pas d'authentification mutuelle
>
> **C'est pourquoi un service mesh (Istio) ajoute de la valeur :** il authentifie chaque service avec un certificat X.509 lié à son ServiceAccount. Un pod avec un faux label mais le mauvais SA serait bloqué.

```bash
# Nettoyer l'imposteur
kubectl delete pod impostor -n $NAMESPACE
```

---

## Étape 8 — Test de rupture : oubli de la règle DNS

```bash
# Supprimer temporairement la politique DNS
kubectl delete networkpolicy allow-dns -n $NAMESPACE

# Tester la résolution de noms
kubectl exec $FRONTEND_POD -n $NAMESPACE -- wget -qO- --timeout=3 http://backend:8080
```

**Output attendu :**

```
wget: bad address 'backend'
```

> **Sans la règle DNS, les pods ne peuvent plus résoudre les noms de services.** L'erreur `bad address` (et non `timeout`) indique un problème de résolution DNS, pas de connectivité réseau.
>
> **C'est l'erreur la plus fréquente** lors de la mise en place de Network Policies avec `default-deny` en egress. Toujours inclure la règle DNS en premier.

```bash
# Ré-appliquer la politique DNS
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: $NAMESPACE
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector: {}
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
EOF

# Vérifier que ça fonctionne à nouveau
kubectl exec $FRONTEND_POD -n $NAMESPACE -- wget -qO- --timeout=3 http://backend:8080
```

---

## Étape 9 — Visualiser les Network Policies

```bash
# Lister toutes les politiques
kubectl get networkpolicies -n $NAMESPACE
```

**Output attendu :**

```
NAME                             POD-SELECTOR     AGE
allow-dns                        <none>           5m
backend-from-frontend-ingress    app=backend      4m
backend-to-database-egress       app=backend      3m
database-from-backend-ingress    app=database     3m
default-deny-all                 <none>           6m
frontend-to-backend-egress       app=frontend     4m
```

```bash
# Détail d'une politique
kubectl describe networkpolicy database-from-backend-ingress -n $NAMESPACE
```

**Output attendu :**

```
Name:         database-from-backend-ingress
Namespace:    lab-netpol
Spec:
  PodSelector:     app=database
  Allowing ingress traffic:
    To Port: 80/TCP
    From:
      PodSelector: app=backend
  Not affecting egress traffic
  Policy Types: Ingress
```

> Pour visualiser les politiques de manière graphique, l'outil en ligne [editor.networkpolicy.io](https://editor.networkpolicy.io) permet de coller un manifeste et de voir un diagramme des flux autorisés.

---

# PARTIE B — Istio & mTLS (mode explicatif)

> **Important :** Istio nécessite environ 1 vCPU + 1.5 Gi RAM pour le control plane (`istiod`) seul. Sur un nœud B2s (2 vCPU, 4 Gi RAM total), il ne reste pas assez de ressources après les pods système AKS. Cette partie étudie les manifestes et concepts **sans les appliquer**.

## Étape 10 — Architecture Istio

### 10.1 Le Control Plane (`istiod`)

```
┌─────────────────────────────────────────────────────┐
│                    istiod                             │
│                                                      │
│  ┌──────────┐  ┌───────────┐  ┌──────────────────┐ │
│  │  Pilot   │  │  Citadel  │  │  Configuration   │ │
│  │          │  │           │  │  (Galley)        │ │
│  │ Distribue│  │ Émet les  │  │ Valide les       │ │
│  │ la config│  │ certificats│  │ manifestes       │ │
│  │ aux proxy│  │ X.509     │  │ Istio            │ │
│  └──────────┘  └───────────┘  └──────────────────┘ │
└─────────────────────────────────────────────────────┘
```

| Composant | Rôle |
|-----------|------|
| Pilot | Distribue la configuration réseau (routes, policies) aux sidecars Envoy |
| Citadel | Génère et distribue les certificats X.509 pour le mTLS (durée : 24h) |
| Galley | Valide la configuration Istio avant de l'appliquer |

### 10.2 Le Data Plane (sidecar Envoy)

```
Pod avec sidecar Istio :
┌────────────────────────────────────────────┐
│  Pod                                        │
│  ┌────────────────┐  ┌──────────────────┐  │
│  │  Conteneur App │  │  Sidecar Envoy   │  │
│  │  (votre code)  │  │  (proxy L7)      │  │
│  │                │  │                   │  │
│  │  localhost:8080◄──┤  Intercepte tout  │  │
│  │                │  │  le trafic IN/OUT │  │
│  └────────────────┘  └───────┬──────────┘  │
└───────────────────────────────┼─────────────┘
                                │
                         ◄──── mTLS ────►
                                │
┌───────────────────────────────┼─────────────┐
│  Pod B                        │             │
│  ┌──────────────────┐  ┌─────┴────────┐    │
│  │  Sidecar Envoy   │  │ Conteneur App│    │
│  │  Vérifie le cert │──►│             │    │
│  │  + déchiffre     │  │              │    │
│  └──────────────────┘  └──────────────┘    │
└─────────────────────────────────────────────┘
```

> Le sidecar est injecté automatiquement par un **mutating webhook** quand le namespace porte le label `istio-injection: enabled`. L'application ne sait pas qu'Envoy intercepte son trafic — c'est transparent.

### 10.3 Injection du sidecar

```bash
# Commande pour activer l'injection (NE PAS EXÉCUTER sur B2s)
# kubectl label namespace $NAMESPACE istio-injection=enabled
```

---

## Étape 11 — PeerAuthentication : forcer le mTLS

### 11.1 Manifeste commenté

```yaml
# PeerAuthentication — force le mTLS pour tout le namespace
# (NE PAS APPLIQUER — mode explicatif)
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default                    # "default" = s'applique à tout le namespace
  namespace: lab-netpol
spec:
  mtls:
    mode: STRICT                   # Tout le trafic DOIT être chiffré en mTLS
```

### 11.2 Modes de PeerAuthentication

| Mode | Comportement |
|------|-------------|
| `DISABLE` | Pas de mTLS — trafic en clair (déconseillé en production) |
| `PERMISSIVE` | Accepte mTLS ET trafic en clair (mode migration) |
| `STRICT` | mTLS obligatoire — refuse tout trafic non chiffré |
| `UNSET` | Hérite du niveau parent (mesh > namespace > workload) |

> **Stratégie de migration recommandée :**
> 1. Commencer en `PERMISSIVE` (accepte les deux) pendant que tous les services reçoivent leur sidecar
> 2. Vérifier que tous les services communiquent en mTLS (`istioctl x describe pod`)
> 3. Passer en `STRICT` quand tous les services ont leur sidecar

### 11.3 Scope des PeerAuthentication

```yaml
# Scope mesh (s'applique à tout le cluster)
# À placer dans le namespace istio-system
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system          # ← mesh-wide
spec:
  mtls:
    mode: STRICT

---
# Scope namespace (s'applique à un namespace)
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: production            # ← namespace-wide
spec:
  mtls:
    mode: STRICT

---
# Scope workload (s'applique à des pods spécifiques)
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: database-strict
  namespace: production
spec:
  selector:
    matchLabels:
      app: database                # ← uniquement ces pods
  mtls:
    mode: STRICT
```

> **Précédence :** workload > namespace > mesh. Un workload en `PERMISSIVE` dans un namespace `STRICT` acceptera le trafic en clair.

---

## Étape 12 — DestinationRule : mode TLS client

### 12.1 Manifeste commenté

```yaml
# DestinationRule — configure le client pour utiliser mTLS
# (NE PAS APPLIQUER — mode explicatif)
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: backend-mtls
  namespace: lab-netpol
spec:
  host: backend.lab-netpol.svc.cluster.local  # Service cible
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL           # Utilise les certificats gérés par Istio
```

### 12.2 Modes TLS dans DestinationRule

| Mode | Comportement |
|------|-------------|
| `DISABLE` | Pas de TLS côté client (trafic en clair) |
| `SIMPLE` | TLS classique (le client vérifie le serveur, pas l'inverse) |
| `MUTUAL` | mTLS avec certificats fournis manuellement |
| `ISTIO_MUTUAL` | mTLS avec certificats gérés automatiquement par Istio (recommandé) |

> **`ISTIO_MUTUAL` vs `MUTUAL` :** avec `ISTIO_MUTUAL`, vous n'avez pas à gérer les certificats — Istio les génère, les distribue et les renouvelle automatiquement (toutes les 24h). Avec `MUTUAL`, vous devez fournir vos propres certificats.

---

## Étape 13 — Identités SPIFFE et certificats

### 13.1 Format d'identité SPIFFE

Chaque workload dans le mesh reçoit une identité au format SPIFFE :

```
spiffe://cluster.local/ns/<namespace>/sa/<service-account>
```

Exemples :
```
spiffe://cluster.local/ns/lab-netpol/sa/frontend
spiffe://cluster.local/ns/lab-netpol/sa/backend
spiffe://cluster.local/ns/lab-netpol/sa/database
```

> L'identité est liée au **ServiceAccount**, pas au label. Un pod imposteur avec le label `app: frontend` mais le ServiceAccount `default` aurait l'identité `spiffe://.../sa/default` — il serait bloqué par les AuthorizationPolicies.
>
> **C'est la solution au problème du label spoofing** démontré à l'étape 7.

### 13.2 Certificats X.509

```
Contenu du certificat émis par Citadel :
┌──────────────────────────────────────────────────┐
│  Subject Alternative Name (SAN) :                 │
│    URI: spiffe://cluster.local/ns/lab-netpol/sa/backend
│                                                   │
│  Issuer: istiod.istio-system.svc                 │
│  Validity: 24h (renouvellement automatique)      │
│  Key: ECDSA P-256                                │
└──────────────────────────────────────────────────┘
```

Commandes de vérification (sur un cluster avec Istio) :

```bash
# Voir les certificats d'un pod (NE PAS EXÉCUTER)
# istioctl proxy-config secret <pod-name> -n $NAMESPACE

# Vérifier si le mTLS est actif entre deux services
# istioctl x describe pod <pod-name> -n $NAMESPACE
```

---

## Étape 14 — AuthorizationPolicy : contrôle d'accès L7

### 14.1 Default deny Istio (similaire à NetworkPolicy mais L7)

```yaml
# AuthorizationPolicy — deny all (NE PAS APPLIQUER)
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: lab-netpol
spec: {}                           # spec vide = deny all
```

### 14.2 Allow spécifique basé sur l'identité

```yaml
# AuthorizationPolicy — autorise frontend → backend uniquement en GET/POST
# (NE PAS APPLIQUER — mode explicatif)
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: allow-frontend-to-backend
  namespace: lab-netpol
spec:
  selector:
    matchLabels:
      app: backend                 # S'applique au backend
  action: ALLOW
  rules:
  - from:
    - source:
        principals:
        - "cluster.local/ns/lab-netpol/sa/frontend"   # Identité SPIFFE
    to:
    - operation:
        methods: ["GET", "POST"]   # Uniquement ces méthodes HTTP
        ports: ["8080"]
```

### 14.3 Comparaison Network Policies vs Istio AuthorizationPolicy

| Aspect | NetworkPolicy | Istio AuthorizationPolicy |
|--------|--------------|--------------------------|
| Identité | Labels (usurpables) | Certificat X.509 / SPIFFE |
| Chiffrement | Non | mTLS automatique |
| Granularité | IP + port (L3/L4) | Méthode HTTP, path, headers (L7) |
| Authentification | Aucune | Mutuelle (client + serveur) |
| Observabilité | Limitée | Métriques, traces, logs par requête |
| Overhead | Zéro | ~2ms latence (proxy Envoy) |
| Prérequis | CNI compatible | Istio installé (~1.5 Gi RAM) |

> **En production, les deux sont complémentaires :**
> - Network Policies = première couche de défense (L3/L4, pas d'overhead)
> - Istio AuthorizationPolicy = deuxième couche (L7, identité forte, chiffrement)
>
> Network Policies bloquent le trafic au niveau noyau (iptables/eBPF), Istio le filtre au niveau applicatif (proxy Envoy).

---

## Étape 15 — Installer Istio (référence pour clusters plus grands)

### Commande d'installation (NE PAS EXÉCUTER sur B2s)

```bash
# Installation avec le profil minimal
# istioctl install --set profile=minimal -y

# Ou via le addon Azure Service Mesh (Istio managé par Azure)
# az aks mesh enable --resource-group $RG --name $CLUSTER_NAME
```

### Ressources requises par profil

| Profil | istiod CPU | istiod RAM | Nœuds min | Cas d'usage |
|--------|-----------|-----------|-----------|-------------|
| `minimal` | 500m | 1 Gi | 2 (Standard_B2s) | Test/dev |
| `default` | 500m | 2 Gi | 3 (Standard_D2s_v3) | Production |
| `demo` | 100m | 512 Mi | 1 (limité) | Démos rapides |

> **Sur votre cluster B2s (1 nœud, 2 vCPU, 4 Gi) :**
> - Les pods système AKS consomment déjà ~800m CPU et ~1.5 Gi RAM
> - Il reste ~1.2 vCPU et ~2.5 Gi pour vos pods
> - istiod (minimal) demande 500m CPU + 1 Gi RAM → il ne resterait presque rien pour les workloads
>
> **Recommandation :** pour tester Istio en vrai, utiliser au minimum 2 nœuds Standard_D2s_v3 (2 vCPU, 8 Gi chacun).

### Alternative : Azure Service Mesh (Istio managé)

```bash
# Activer l'addon (gère istiod automatiquement)
# az aks mesh enable --resource-group $RG --name $CLUSTER_NAME

# Avantages :
# - Istiod managé par Azure (pas dans votre cluster)
# - Mises à jour automatiques
# - Intégration Azure Monitor
# - Même API Istio (PeerAuthentication, AuthorizationPolicy, etc.)
```

---

## Étape 16 — Scénario complet mTLS bout-en-bout

Voici ce qui se passe quand le frontend appelle le backend dans un mesh Istio en mode STRICT :

```
┌─ Pod Frontend ─────────────────────────────────────────────────────────────┐
│                                                                             │
│  1. App envoie GET http://backend:8080/api/data                            │
│     │                                                                       │
│     ▼                                                                       │
│  2. Envoy sidecar intercepte la requête (iptables redirect)                │
│     │                                                                       │
│     ▼                                                                       │
│  3. Envoy présente son certificat X.509 :                                  │
│     SAN: spiffe://cluster.local/ns/lab-netpol/sa/frontend                  │
│                                                                             │
└─────────────────────────────────┬───────────────────────────────────────────┘
                                  │
                            mTLS (chiffré)
                                  │
┌─ Pod Backend ───────────────────┼───────────────────────────────────────────┐
│                                 ▼                                            │
│  4. Envoy sidecar reçoit la connexion                                       │
│     │                                                                        │
│     ▼                                                                        │
│  5. Vérifie le certificat du frontend auprès de la CA (istiod)             │
│     ✓ Certificat valide, non expiré, émis par la bonne CA                  │
│     │                                                                        │
│     ▼                                                                        │
│  6. Vérifie l'AuthorizationPolicy :                                         │
│     ✓ Source "cluster.local/ns/lab-netpol/sa/frontend" autorisée           │
│     ✓ Méthode GET autorisée                                                │
│     ✓ Port 8080 autorisé                                                   │
│     │                                                                        │
│     ▼                                                                        │
│  7. Déchiffre et transmet la requête à l'app sur localhost:8080            │
│     │                                                                        │
│     ▼                                                                        │
│  8. App backend traite la requête et répond                                 │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

> **Points clés :**
> - L'application n'a rien à modifier — Envoy gère le TLS de manière transparente
> - Les certificats sont renouvelés toutes les 24h sans interruption
> - Un pod imposteur (mauvais SA) serait bloqué à l'étape 6 (identité non autorisée)
> - Le trafic entre les pods est chiffré — même un attaquant qui capture le réseau ne peut pas lire les données

---

## Nettoyage des ressources

```bash
# Supprimer le namespace (supprime tous les pods, services, network policies)
kubectl delete namespace $NAMESPACE

# Vérifier
kubectl get namespaces | grep lab-netpol
```

> La suppression du namespace supprime automatiquement toutes les Network Policies, Deployments, Services et Pods créés pendant le lab.

---

## Récapitulatif des concepts vus

| Concept | Ce que vous avez fait |
|---|---|
| Réseau plat par défaut | Démontré que tous les pods communiquent sans restriction |
| Default-deny | Politique qui bloque tout le trafic (Ingress + Egress) |
| Règle DNS obligatoire | Sans elle, la résolution de noms échoue (erreur fréquente) |
| Egress + Ingress pair | Les deux côtés doivent autoriser le flux |
| `podSelector` | Cibler les pods par labels dans les Network Policies |
| Label spoofing | Limitation : les labels sont usurpables → besoin de mTLS |
| Istio sidecar | Proxy Envoy injecté dans chaque pod (transparent) |
| PeerAuthentication | Force le mTLS entre les services (mode STRICT) |
| DestinationRule | Configure le mode TLS côté client (ISTIO_MUTUAL) |
| Identité SPIFFE | Identité cryptographique basée sur le ServiceAccount |
| AuthorizationPolicy | Contrôle d'accès L7 basé sur l'identité (non les labels) |
| Complémentarité | NetworkPolicy (L3/L4) + Istio (L7) = défense en profondeur |

---

## Questions de vérification

1. Pourquoi faut-il explicitement autoriser le DNS (port 53) dans une politique default-deny egress ? Que se passe-t-il si on l'oublie ?
2. Un pod avec le label `app: frontend` mais le ServiceAccount `default` peut-il accéder au backend avec les Network Policies actuelles ? Et avec Istio ?
3. Quelle est la différence entre `podSelector` et `namespaceSelector` dans une NetworkPolicy ? Quand utiliser l'un ou l'autre ?
4. Pourquoi Istio utilise-t-il des certificats avec une durée de vie de 24h ? Quel problème cela résout-il ?
5. Un développeur crée un service sans Network Policy dans un namespace qui a un default-deny. Que se passe-t-il pour ce service ?
6. Expliquez pourquoi Network Policies et Istio AuthorizationPolicies sont complémentaires plutôt que redondantes.

---

## Pour aller plus loin

- **Cilium** : alternative CNI avec support eBPF, Network Policies L7 natives (sans service mesh), et observabilité intégrée (Hubble). Peut remplacer à la fois Calico (L3/L4) et partiellement Istio (L7).
- **Azure Service Mesh (Istio-based)** : addon AKS qui installe un Istio managé. Le control plane est géré par Azure (pas dans votre cluster). Activation : `az aks mesh enable`.
- **mTLS sans Istio** : des solutions comme Linkerd (plus léger qu'Istio, ~100Mi RAM) ou cert-manager + nginx sidecar permettent du mTLS sans la complexité d'Istio.
- **Network Policy Editor** : l'outil [editor.networkpolicy.io](https://editor.networkpolicy.io) permet de visualiser et générer des Network Policies graphiquement.
- **eBPF-based policies** : avec Cilium, les Network Policies sont appliquées au niveau kernel (eBPF) au lieu d'iptables — meilleures performances et visibilité L7 sans proxy.
