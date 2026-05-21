# LAB AVANCÉ — Pod Disruption Budget & Rolling Update : zéro downtime

> Maîtriser les mises à jour sans interruption avec les rolling updates, protéger la disponibilité des pods avec les PDB, et diagnostiquer les situations de blocage.
> Durée estimée : 1h15 · Niveau : Avancé

---

## Objectifs

**Partie A — Rolling Update : déploiement sans interruption (35 min)**
- Déployer un Deployment avec la stratégie `RollingUpdate`
- Comprendre et configurer `maxUnavailable` et `maxSurge`
- Observer un rolling update en temps réel
- Effectuer un rollback vers une version précédente
- Diagnostiquer un déploiement échoué (image inexistante)
- Comparer `RollingUpdate` vs `Recreate`

**Partie B — Pod Disruption Budget (40 min)**
- Comprendre les disruptions volontaires vs involontaires
- Créer un PDB avec `minAvailable` et `maxUnavailable`
- Observer le comportement du PDB lors d'un drain de nœud
- Diagnostiquer un drain bloqué par un PDB trop restrictif

---

## Contexte

### Pourquoi les rolling updates ?

```
Sans rolling update (stratégie Recreate) :
  v1 v1 v1  →  ∅ ∅ ∅  →  v2 v2 v2
              ↑ DOWNTIME ↑
  Tous les pods sont tués AVANT de créer les nouveaux

Avec rolling update :
  v1 v1 v1  →  v1 v1 v2  →  v1 v2 v2  →  v2 v2 v2
              ↑ pas de downtime — toujours au moins 2 pods disponibles
```

### Pourquoi les PDB ?

```
Sans PDB :
  kubectl drain node-1
  → Kubernetes évacue TOUS les pods d'un coup
  → si tous les réplicas sont sur ce nœud → downtime

Avec PDB (minAvailable: 1) :
  kubectl drain node-1
  → Kubernetes évacue les pods UN PAR UN
  → attend qu'un nouveau pod soit Ready avant d'évacuer le suivant
  → au moins 1 pod toujours disponible
```

### Disruptions volontaires vs involontaires

```
Volontaires (contrôlables par PDB) :      Involontaires (non contrôlables) :
─────────────────────────────────          ──────────────────────────────────
kubectl drain (maintenance nœud)           Crash du nœud (panne hardware)
kubectl delete pod                         OOMKill (mémoire insuffisante)
Mise à jour du cluster AKS                 Crash du conteneur (bug applicatif)
Scale-down d'un node pool                  Perte réseau
```

---

## Prérequis

> Ce lab suppose que le Lab 1 est terminé :
>
> - Cluster AKS fonctionnel
> - Variables `$RG` et `$CLUSTER_NAME` définies
> - `kubectl` configuré

```bash
# Vérifications
kubectl get nodes
```

**Output attendu :**

```
NAME                                STATUS   ROLES    AGE   VERSION
aks-nodepool1-XXXXXXXX-vmssXXXXXX  Ready    <none>   ...   v1.3X.X
```

---

## Étape 0 — Variables d'environnement

```bash
source ~/.lab1-env 2>/dev/null || true
export NAMESPACE="lab-pdb-rolling"
export NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')

echo "Cluster   : $CLUSTER_NAME"
echo "Namespace : $NAMESPACE"
echo "Nœud      : $NODE_NAME"
```

```bash
kubectl create namespace $NAMESPACE
```

---

# PARTIE A — Rolling Update : déploiement sans interruption

## Étape 1 — Déployer un Deployment avec RollingUpdate

```bash
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app
  namespace: $NAMESPACE
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web-app
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1    # Au plus 1 pod indisponible pendant la mise à jour
      maxSurge: 1           # Au plus 1 pod supplémentaire créé pendant la mise à jour
  template:
    metadata:
      labels:
        app: web-app
    spec:
      containers:
      - name: nginx
        image: nginx:1.24-alpine
        ports:
        - containerPort: 80
        resources:
          requests: { cpu: "25m", memory: "32Mi" }
          limits:   { cpu: "50m", memory: "64Mi" }
EOF
```

```bash
# Attendre que tous les pods soient prêts
kubectl rollout status deployment/web-app -n $NAMESPACE

# Vérifier
kubectl get pods -n $NAMESPACE -l app=web-app -o wide
```

**Output attendu :**

```
NAME                      READY   STATUS    RESTARTS   AGE   IP           NODE
web-app-xxxxxxxxx-xxxxx   1/1     Running   0          15s   10.244.x.x  aks-...
web-app-xxxxxxxxx-xxxxx   1/1     Running   0          15s   10.244.x.x  aks-...
web-app-xxxxxxxxx-xxxxx   1/1     Running   0          15s   10.244.x.x  aks-...
```

---

## Étape 2 — Comprendre maxUnavailable et maxSurge

```
Deployment : replicas=3, maxUnavailable=1, maxSurge=1

  Au repos : 3 pods v1 disponibles

  Pendant le rolling update (mise à jour v1 → v2) :

  Nombre de pods   = replicas + maxSurge = 3 + 1 = 4 max
  Pods disponibles = replicas - maxUnavailable = 3 - 1 = 2 min

  Déroulement :
  ┌─────────────────────────────────────────────────────────┐
  │ Étape 1 : Créer 1 pod v2 (maxSurge=1)                  │
  │           v1 v1 v1 v2(creating)    → 4 pods, 3 ready   │
  │                                                         │
  │ Étape 2 : v2 est Ready → tuer 1 pod v1 (maxUnavail=1)  │
  │           v1 v1 v2 (v1 terminating) → 3 pods, 2 ready  │
  │                                                         │
  │ Étape 3 : Créer 1 nouveau pod v2                        │
  │           v1 v2 v2(creating)        → 4 pods, 2 ready  │
  │                                                         │
  │ Étape 4 : v2 est Ready → tuer 1 pod v1                 │
  │           v2 v2 (v1 terminating)    → 3 pods, 2 ready  │
  │                                                         │
  │ Étape 5 : Créer le dernier pod v2                       │
  │           v2 v2 v2(creating)        → 3 pods, 2 ready  │
  │                                                         │
  │ Fin : v2 v2 v2                      → 3 pods, 3 ready  │
  └─────────────────────────────────────────────────────────┘
```

> | Paramètre | Signification | Effet |
> |-----------|---------------|-------|
> | `maxUnavailable: 0` | Aucun pod indisponible | Plus lent mais zéro downtime garanti |
> | `maxUnavailable: 1` | 1 pod peut être absent | Bon compromis vitesse/disponibilité |
> | `maxSurge: 0` | Pas de pod supplémentaire | Économe en ressources mais plus lent |
> | `maxSurge: 1` | 1 pod en plus temporairement | Plus rapide, consomme légèrement plus |
> | `maxSurge: 100%` | Double le nombre de pods | Très rapide (blue-green like) |

---

## Étape 3 — Déclencher un rolling update

```bash
# Dans un premier terminal : observer les pods en temps réel
kubectl get pods -n $NAMESPACE -l app=web-app -w
```

```bash
# Dans un second terminal (ou après Ctrl+C) : mettre à jour l'image
kubectl set image deployment/web-app nginx=nginx:1.25-alpine -n $NAMESPACE

# Observer le rollout
kubectl rollout status deployment/web-app -n $NAMESPACE
```

**Output attendu (kubectl rollout status) :**

```
Waiting for deployment "web-app" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "web-app" rollout to finish: 2 out of 3 new replicas have been updated...
Waiting for deployment "web-app" rollout to finish: 2 of 3 updated replicas are available...
deployment "web-app" successfully rolled out
```

```bash
# Vérifier la version de l'image
kubectl get deployment web-app -n $NAMESPACE \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
echo
```

**Output attendu :**

```
nginx:1.25-alpine
```

> Pendant le rolling update, Kubernetes a toujours maintenu au moins 2 pods disponibles (replicas - maxUnavailable = 3 - 1 = 2). Les clients n'ont jamais perdu le service.

---

## Étape 4 — Historique des déploiements

```bash
kubectl rollout history deployment/web-app -n $NAMESPACE
```

**Output attendu :**

```
deployment.apps/web-app
REVISION  CHANGE-CAUSE
1         <none>
2         <none>
```

```bash
# Voir les détails d'une révision
kubectl rollout history deployment/web-app -n $NAMESPACE --revision=1
kubectl rollout history deployment/web-app -n $NAMESPACE --revision=2
```

> Chaque mise à jour crée une nouvelle révision. Kubernetes garde l'historique (par défaut les 10 dernières, configurable via `spec.revisionHistoryLimit`).

---

## Étape 5 — Rollback

```bash
# Revenir à la version précédente (revision 1 = nginx:1.24-alpine)
kubectl rollout undo deployment/web-app -n $NAMESPACE

# Vérifier
kubectl rollout status deployment/web-app -n $NAMESPACE
kubectl get deployment web-app -n $NAMESPACE \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
echo
```

**Output attendu :**

```
deployment "web-app" successfully rolled out
nginx:1.24-alpine
```

```bash
# L'historique montre maintenant 3 révisions
kubectl rollout history deployment/web-app -n $NAMESPACE
```

**Output attendu :**

```
deployment.apps/web-app
REVISION  CHANGE-CAUSE
2         <none>
3         <none>
```

> Le rollback est lui-même un rolling update — il suit les mêmes règles de `maxUnavailable`/`maxSurge`. La révision 1 disparaît car elle est devenue la révision 3.

---

## Étape 6 — Test de rupture : image inexistante

```bash
# Déployer une image qui n'existe pas
kubectl set image deployment/web-app nginx=nginx:version-inexistante -n $NAMESPACE

# Observer (attendre ~30s)
kubectl get pods -n $NAMESPACE -l app=web-app
```

**Output attendu :**

```
NAME                      READY   STATUS             RESTARTS   AGE
web-app-xxxxxxxxx-xxxxx   1/1     Running            0          2m     ← ancien pod v1 (toujours là)
web-app-xxxxxxxxx-xxxxx   1/1     Running            0          2m     ← ancien pod v1 (toujours là)
web-app-yyyyyyyyy-yyyyy   0/1     ImagePullBackOff   0          30s    ← nouveau pod échoué
```

```bash
# Voir le statut du rollout
kubectl rollout status deployment/web-app -n $NAMESPACE --timeout=10s 2>&1 || true
```

**Output attendu :**

```
Waiting for deployment "web-app" rollout to finish: 1 out of 3 new replicas have been updated...
error: timed out waiting for the condition
```

> **Diagnostic :** le rolling update est bloqué. Grâce à `maxUnavailable: 1`, Kubernetes a tué 1 ancien pod et créé 1 nouveau pod. Le nouveau pod ne démarre pas (`ImagePullBackOff`) mais les 2 anciens pods sont toujours Running. Le service est dégradé (2/3 pods) mais pas en panne totale.
>
> Sans `maxUnavailable`, tous les anciens pods auraient été tués → downtime complet.

```bash
# Rollback immédiat
kubectl rollout undo deployment/web-app -n $NAMESPACE
kubectl rollout status deployment/web-app -n $NAMESPACE

# Vérifier que tout est revenu à la normale
kubectl get pods -n $NAMESPACE -l app=web-app
```

**Output attendu :**

```
NAME                      READY   STATUS    RESTARTS   AGE
web-app-xxxxxxxxx-xxxxx   1/1     Running   0          3m
web-app-xxxxxxxxx-xxxxx   1/1     Running   0          3m
web-app-xxxxxxxxx-xxxxx   1/1     Running   0          10s
```

---

## Étape 7 — Comparer RollingUpdate vs Recreate

### 7.1 Stratégie Recreate

```bash
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-recreate
  namespace: $NAMESPACE
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web-recreate
  strategy:
    type: Recreate        # ← Tous les pods sont tués AVANT de créer les nouveaux
  template:
    metadata:
      labels:
        app: web-recreate
    spec:
      containers:
      - name: nginx
        image: nginx:1.24-alpine
        ports:
        - containerPort: 80
        resources:
          requests: { cpu: "25m", memory: "32Mi" }
          limits:   { cpu: "50m", memory: "64Mi" }
EOF

kubectl rollout status deployment/web-recreate -n $NAMESPACE
```

```bash
# Mettre à jour — observer la différence
kubectl set image deployment/web-recreate nginx=nginx:1.25-alpine -n $NAMESPACE

# Observer les pods
kubectl get pods -n $NAMESPACE -l app=web-recreate -w
```

**Output attendu (observer la séquence) :**

```
web-recreate-xxxxx   1/1     Terminating   0   30s
web-recreate-xxxxx   1/1     Terminating   0   30s
web-recreate-xxxxx   1/1     Terminating   0   30s    ← tous tués d'abord
web-recreate-yyyyy   0/1     Pending       0   0s
web-recreate-yyyyy   0/1     Pending       0   0s
web-recreate-yyyyy   0/1     Pending       0   0s     ← puis tous recréés
web-recreate-yyyyy   1/1     Running       0   5s
web-recreate-yyyyy   1/1     Running       0   5s
web-recreate-yyyyy   1/1     Running       0   5s
```

> **Comparaison :**
>
> | | RollingUpdate | Recreate |
> |---|---|---|
> | Downtime | Non (pods remplacés progressivement) | Oui (tous tués puis recréés) |
> | Vitesse | Plus lent (étape par étape) | Plus rapide (tout d'un coup) |
> | Ressources | Temporairement +maxSurge pods | Pas de pods supplémentaires |
> | Cas d'usage | Production, API, services web | Migrations BDD, changements incompatibles |

```bash
# Nettoyer le deployment Recreate
kubectl delete deployment web-recreate -n $NAMESPACE
```

---

# PARTIE B — Pod Disruption Budget

> **Avant de commencer :** sur un nœud B2s, s'assurer qu'il ne reste que le deployment `web-app` :
>
> ```bash
> kubectl get pods -n $NAMESPACE
> ```
>
> Seuls les 3 pods `web-app-*` doivent être présents.

## Étape 8 — Comprendre les PDB

```
Pod Disruption Budget (PDB) :
  "Kubernetes, tu peux évacuer des pods pour maintenance,
   mais tu dois TOUJOURS en garder au moins N disponibles"

Exemple avec 3 réplicas et PDB minAvailable=2 :

  kubectl drain node-1
     │
     ├── Peut-on évacuer pod-1 ? → 3 pods running, min=2 → OUI (3-1=2 ≥ 2)
     │   → pod-1 évacué → 2 pods running
     │
     ├── Peut-on évacuer pod-2 ? → 2 pods running, min=2 → NON (2-1=1 < 2)
     │   → Kubernetes attend qu'un nouveau pod soit Ready
     │   → nouveau pod Ready → 3 pods running
     │
     └── Peut-on évacuer pod-2 ? → 3 pods running, min=2 → OUI
         → pod-2 évacué
```

> **Important sur un cluster mono-nœud :** quand on `drain` le seul nœud, les pods évacués ne peuvent pas être re-schedulés (le nœud est marqué `SchedulingDisabled`). Le PDB va bloquer le drain car il ne peut pas maintenir le `minAvailable`. C'est le comportement attendu — on verra comment le gérer.

---

## Étape 9 — Créer un PDB avec minAvailable

```bash
cat <<EOF | kubectl apply -f -
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: pdb-web-app
  namespace: $NAMESPACE
spec:
  minAvailable: 2            # Au moins 2 pods doivent rester disponibles
  selector:
    matchLabels:
      app: web-app           # S'applique aux pods avec ce label
EOF
```

```bash
# Vérifier le PDB
kubectl get pdb -n $NAMESPACE
```

**Output attendu :**

```
NAME          MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
pdb-web-app   2               N/A               1                     5s
```

> | Colonne | Signification |
> |---------|---------------|
> | `MIN AVAILABLE` | Nombre minimum de pods qui doivent rester disponibles |
> | `MAX UNAVAILABLE` | Nombre maximum de pods pouvant être indisponibles (N/A car on utilise minAvailable) |
> | `ALLOWED DISRUPTIONS` | Combien de pods peuvent être évacués maintenant (3 running - 2 min = 1) |

```bash
# Détails complets
kubectl get pdb pdb-web-app -n $NAMESPACE -o yaml | grep -A5 status
```

**Output attendu :**

```yaml
status:
  currentHealthy: 3
  desiredHealthy: 2
  disruptionsAllowed: 1
  expectedPods: 3
```

---

## Étape 10 — Simuler un drain de nœud

> **Attention :** sur un cluster mono-nœud, le drain marque le nœud comme `SchedulingDisabled`. Les pods systèmes sont protégés par `--ignore-daemonsets`. On va utiliser `--timeout` pour limiter le blocage et `kubectl uncordon` immédiatement après.

```bash
# Tenter le drain (va se bloquer car mono-nœud + PDB)
# --timeout=30s pour ne pas attendre indéfiniment
# --ignore-daemonsets pour ignorer les pods DaemonSet (système)
# --delete-emptydir-data pour ignorer les volumes emptyDir
kubectl drain $NODE_NAME \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --timeout=30s 2>&1 || true
```

**Output attendu :**

```
node/aks-nodepool1-xxxxx cordoned
evicting pod lab-pdb-rolling/web-app-xxxxx
error when evicting pods/"web-app-xxxxx" -n "lab-pdb-rolling" (will retry after 5s):
Cannot evict pod as it would violate the pod's disruption budget.
...
There are pending pods in node "aks-nodepool1-xxxxx" when an error occurred:
timed out waiting for the condition
```

> **Ce qui s'est passé :**
> 1. Le nœud a été cordonné (`SchedulingDisabled`)
> 2. Kubernetes a tenté d'évacuer un pod
> 3. Le PDB autorise 1 disruption → le premier pod est évacué
> 4. Le pod évacué ne peut pas être re-schedulé (nœud cordonné = seul nœud)
> 5. Le PDB voit seulement 2 pods (dont 1 en Pending) → refuse d'en évacuer un autre
> 6. Timeout après 30s

```bash
# IMPORTANT : remettre le nœud en service immédiatement
kubectl uncordon $NODE_NAME

# Vérifier que le nœud est Ready
kubectl get nodes
```

**Output attendu :**

```
NAME                                STATUS   ROLES    AGE   VERSION
aks-nodepool1-XXXXXXXX-vmssXXXXXX  Ready    <none>   ...   v1.3X.X
```

```bash
# Attendre que les pods reviennent à 3/3
kubectl rollout status deployment/web-app -n $NAMESPACE
kubectl get pods -n $NAMESPACE -l app=web-app
```

> Le PDB a protégé le service : même pendant le drain, au moins 2 pods étaient disponibles. Sur un cluster multi-nœuds, les pods évacués auraient été re-schedulés sur d'autres nœuds automatiquement.

---

## Étape 11 — PDB avec maxUnavailable

Autre syntaxe : au lieu de dire "garde au moins N pods", on dit "tu peux en casser au plus N".

```bash
# Supprimer l'ancien PDB
kubectl delete pdb pdb-web-app -n $NAMESPACE

# Créer avec maxUnavailable
cat <<EOF | kubectl apply -f -
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: pdb-web-app
  namespace: $NAMESPACE
spec:
  maxUnavailable: 1          # Au plus 1 pod indisponible à la fois
  selector:
    matchLabels:
      app: web-app
EOF
```

```bash
kubectl get pdb -n $NAMESPACE
```

**Output attendu :**

```
NAME          MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
pdb-web-app   N/A             1                 1                     5s
```

> **minAvailable vs maxUnavailable :**
>
> | | `minAvailable: 2` | `maxUnavailable: 1` |
> |---|---|---|
> | Avec 3 réplicas | 2 min dispo, 1 évacuable | 1 max indispo, 2 dispo |
> | Résultat | Identique | Identique |
> | Si scale à 5 réplicas | 2 min dispo, **3** évacuables | 1 max indispo, **4** dispo |
> | Préférer quand | On veut un minimum absolu | On veut limiter les disruptions |

---

## Étape 12 — Observer le statut du PDB en détail

```bash
# Statut complet
kubectl describe pdb pdb-web-app -n $NAMESPACE
```

**Output attendu :**

```
Name:           pdb-web-app
Namespace:      lab-pdb-rolling
Max unavailable: 1
Selector:       app=web-app
Status:
    Allowed disruptions:  1
    Current:              3
    Desired:              2
    Total:                3
Events:                   <none>
```

> | Champ | Signification |
> |-------|---------------|
> | `Allowed disruptions` | Combien de pods Kubernetes peut évacuer maintenant |
> | `Current` | Nombre de pods actuellement en bonne santé |
> | `Desired` | Nombre minimum de pods qui doivent rester en bonne santé |
> | `Total` | Nombre total de pods sélectionnés par le PDB |

```bash
# Simuler la suppression d'un pod et observer le PDB
kubectl delete pod -n $NAMESPACE -l app=web-app --field-selector=status.phase=Running --wait=false | head -1

# Vérifier immédiatement le PDB
kubectl get pdb -n $NAMESPACE
```

> Note : `kubectl delete pod` est une disruption **involontaire** — le PDB ne la bloque pas. Le PDB ne protège que contre les disruptions **volontaires** (drain, eviction API).

---

## Étape 13 — Test de rupture : PDB trop restrictif

```bash
# Supprimer l'ancien PDB
kubectl delete pdb pdb-web-app -n $NAMESPACE

# Attendre que les 3 pods soient Ready
kubectl rollout status deployment/web-app -n $NAMESPACE

# PDB trop restrictif : minAvailable = replicas (aucune disruption autorisée)
cat <<EOF | kubectl apply -f -
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: pdb-trop-strict
  namespace: $NAMESPACE
spec:
  minAvailable: 3            # Les 3 pods doivent rester → aucune évacuation possible
  selector:
    matchLabels:
      app: web-app
EOF
```

```bash
kubectl get pdb -n $NAMESPACE
```

**Output attendu :**

```
NAME              MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
pdb-trop-strict   3               N/A               0                     5s
```

> `ALLOWED DISRUPTIONS: 0` — Kubernetes ne peut évacuer **aucun** pod.

```bash
# Tenter le drain — sera bloqué immédiatement
kubectl drain $NODE_NAME \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --timeout=15s 2>&1 || true
```

**Output attendu :**

```
node/aks-nodepool1-xxxxx cordoned
evicting pod lab-pdb-rolling/web-app-xxxxx
error when evicting pods/"web-app-xxxxx" -n "lab-pdb-rolling" (will retry after 5s):
Cannot evict pod as it would violate the pod's disruption budget.
...
timed out waiting for the condition
```

```bash
# Remettre le nœud en service
kubectl uncordon $NODE_NAME
```

> **Diagnostic :** le PDB `minAvailable: 3` avec 3 réplicas signifie `ALLOWED DISRUPTIONS: 0`. Le drain ne peut évacuer aucun pod. En production, cela **bloque les mises à jour du cluster AKS** (node surge upgrade) et la maintenance des nœuds.
>
> **Règle :** `minAvailable` doit toujours être **inférieur** au nombre de réplicas. Utiliser `minAvailable: N-1` ou `maxUnavailable: 1`.

```bash
# Nettoyer
kubectl delete pdb pdb-trop-strict -n $NAMESPACE
```

---

## Étape 14 — Test de rupture : 1 réplica + PDB

```bash
# Scaler à 1 seul réplica
kubectl scale deployment/web-app -n $NAMESPACE --replicas=1
kubectl rollout status deployment/web-app -n $NAMESPACE

# PDB avec minAvailable: 1
cat <<EOF | kubectl apply -f -
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: pdb-single-replica
  namespace: $NAMESPACE
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: web-app
EOF
```

```bash
kubectl get pdb -n $NAMESPACE
```

**Output attendu :**

```
NAME                 MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
pdb-single-replica   1               N/A               0                     5s
```

> Même avec `minAvailable: 1`, si on n'a qu'**1 seul réplica**, `ALLOWED DISRUPTIONS` est 0. Le PDB bloque le drain car évacuer le seul pod violerait le budget.
>
> **Leçon :** un PDB n'a de sens qu'avec **au moins 2 réplicas**. Avec 1 réplica, le PDB est toujours bloquant.

```bash
# Remettre 3 réplicas
kubectl scale deployment/web-app -n $NAMESPACE --replicas=3
kubectl rollout status deployment/web-app -n $NAMESPACE

# Nettoyer le PDB
kubectl delete pdb pdb-single-replica -n $NAMESPACE
```

---

## Étape 15 — Combiner PDB et rolling update

```bash
# Recréer un PDB raisonnable
cat <<EOF | kubectl apply -f -
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: pdb-web-app
  namespace: $NAMESPACE
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      app: web-app
EOF
```

```bash
# Déclencher un rolling update
kubectl set image deployment/web-app nginx=nginx:1.25-alpine -n $NAMESPACE

# Observer simultanément le rollout et le PDB
kubectl rollout status deployment/web-app -n $NAMESPACE &
kubectl get pdb -n $NAMESPACE -w &
wait
```

```bash
# Vérifier l'état final
kubectl get pods -n $NAMESPACE -l app=web-app
kubectl get pdb -n $NAMESPACE
```

**Output attendu :**

```
NAME          MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
pdb-web-app   N/A             1                 1                     2m
```

> Le rolling update respecte à la fois :
> - La stratégie du Deployment (`maxUnavailable: 1`, `maxSurge: 1`)
> - Le PDB (`maxUnavailable: 1`)
>
> Le plus restrictif des deux gagne. Si le Deployment autorise `maxUnavailable: 2` mais le PDB dit `maxUnavailable: 1`, seul 1 pod sera évacué à la fois.

---

## Nettoyage des ressources

```bash
# Supprimer le namespace (supprime tous les objets)
kubectl delete namespace $NAMESPACE

# Vérifier que le nœud est en état normal
kubectl get nodes
```

**Output attendu :**

```
NAME                                STATUS   ROLES    AGE   VERSION
aks-nodepool1-XXXXXXXX-vmssXXXXXX  Ready    <none>   ...   v1.3X.X
```

> **Important :** vérifier que le nœud n'est pas resté en `SchedulingDisabled`. Si c'est le cas :
> ```bash
> kubectl uncordon $NODE_NAME
> ```

---

## Récapitulatif des concepts vus

| Concept | Ce que vous avez fait |
|---|---|
| Rolling Update | Mise à jour progressive sans downtime |
| `maxUnavailable` | Limiter le nombre de pods indisponibles pendant l'update |
| `maxSurge` | Contrôler le nombre de pods supplémentaires temporaires |
| `kubectl rollout undo` | Rollback instantané vers la version précédente |
| Stratégie Recreate | Tuer tous les pods avant de recréer (avec downtime) |
| Pod Disruption Budget | Protéger un nombre minimum de pods disponibles |
| `minAvailable` | Nombre minimum de pods qui doivent rester en vie |
| `maxUnavailable` (PDB) | Nombre maximum de pods pouvant être évacués |
| `kubectl drain` | Évacuer tous les pods d'un nœud (maintenance) |
| `kubectl uncordon` | Remettre un nœud en service après un drain |
| `ALLOWED DISRUPTIONS` | Indicateur en temps réel de la marge de disruption |

---

## Questions de vérification

1. Quelle est la différence entre la stratégie `RollingUpdate` et `Recreate` ? Dans quel cas choisir `Recreate` ?
2. Un Deployment a `replicas: 5`, `maxUnavailable: 2`, `maxSurge: 1`. Pendant un rolling update, combien de pods minimum sont disponibles ? Combien de pods maximum existent ?
3. Un rolling update est en cours et les nouveaux pods sont en `ImagePullBackOff`. Que faut-il faire ? Les anciens pods sont-ils toujours disponibles ?
4. Un PDB avec `minAvailable: 3` est appliqué sur un Deployment avec 3 réplicas. Que se passe-t-il lors d'un `kubectl drain` ? Comment corriger ?
5. Pourquoi un PDB ne protège pas contre un `kubectl delete pod` ? Quelle est la différence entre une disruption volontaire et involontaire ?
6. Un cluster multi-nœuds a un Deployment avec 3 réplicas, un PDB `maxUnavailable: 1`, et on lance un upgrade AKS. Décrivez ce qui se passe nœud par nœud.

---

## Pour aller plus loin

- **Readiness Probes + Rolling Update** : un nouveau pod ne reçoit du trafic que quand sa readiness probe passe. Sans readiness probe, Kubernetes considère le pod Ready dès que le conteneur démarre — le trafic arrive avant que l'app soit prête.
- **`minReadySeconds`** : délai supplémentaire avant de considérer un pod comme disponible. Utile pour les applications avec un temps de chauffe (warm-up de cache, connexions pool).
- **Canary deployments** : déployer la nouvelle version sur 1 pod d'abord, valider, puis étendre. Réalisable avec 2 Deployments et un Service qui sélectionne les deux (même label).
- **Blue-green deployments** : deux Deployments complets (blue = actuel, green = nouveau). Switcher le Service d'un coup quand green est validé. Plus de ressources mais rollback instantané.
- **`preStop` hook** : exécuter une commande avant de tuer un pod (drainer les connexions, terminer les requêtes en cours). Essentiel pour les applications avec des connexions longues (WebSocket, gRPC streaming).
- **`terminationGracePeriodSeconds`** : temps accordé au pod pour se terminer proprement après un signal SIGTERM (défaut : 30s). Augmenter pour les applications qui ont besoin de flush des données en mémoire.
