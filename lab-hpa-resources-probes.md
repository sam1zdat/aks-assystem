# LAB AVANCÉ — HPA, Probes & Gestion des Ressources

> Automatiser le scaling des pods avec le HPA, configurer les health checks (probes), maîtriser les requests/limits et les quotas, et exécuter des tâches planifiées avec les Jobs.
> Durée estimée : 1h30 · Niveau : Avancé

---

## Objectifs

**Partie A — Probes : health checks des pods (25 min)**
- Configurer les 3 types de probes : liveness, readiness et startup
- Observer leur comportement via les events Kubernetes
- Diagnostiquer un pod qui redémarre en boucle (livenessProbe fail)
- Diagnostiquer un pod retiré du Service (readinessProbe fail)

**Partie B — Resource Requests, Limits & QoS (25 min)**
- Comprendre les 3 classes QoS (Guaranteed, Burstable, BestEffort)
- Créer un LimitRange pour appliquer des valeurs par défaut
- Créer un ResourceQuota pour limiter les ressources d'un namespace
- Diagnostiquer un OOMKill et un dépassement de quota

**Partie C — HPA : autoscaling horizontal (25 min)**
- Créer un HPA basé sur l'utilisation CPU
- Générer de la charge et observer le scale-up automatique
- Observer le scale-down après arrêt de la charge
- Diagnostiquer un HPA qui ne fonctionne pas (missing requests)

**Partie D — Jobs & CronJobs (15 min)**
- Créer un Job simple et un Job parallèle
- Planifier une tâche récurrente avec un CronJob
- Diagnostiquer un Job en échec (backoffLimit)

---

## Contexte

### Pourquoi ces concepts sont liés

```
                    ┌─────────────────┐
                    │   readinessProbe │ ← Quand un pod scalé est-il prêt ?
                    └────────┬────────┘
                             │
┌──────────────┐    ┌────────▼────────┐    ┌──────────────────┐
│ Requests     │───▶│      HPA        │───▶│ Nouveaux pods    │
│ (CPU/memory) │    │ scale si        │    │ créés            │
│ = base du    │    │ usage/request   │    │ automatiquement  │
│   calcul %   │    │ > target        │    │                  │
└──────────────┘    └────────┬────────┘    └──────────────────┘
                             │
                    ┌────────▼────────┐
                    │ ResourceQuota   │ ← Combien de pods max dans ce namespace ?
                    └─────────────────┘
```

### Les 3 types de probes

```
startupProbe :
  "L'application a-t-elle démarré ?"
  → Pendant le démarrage initial uniquement
  → Si échoue : le pod est tué et redémarré
  → Désactive liveness/readiness tant qu'elle n'a pas réussi

livenessProbe :
  "L'application est-elle encore vivante ?"
  → Vérification continue après le démarrage
  → Si échoue : le pod est tué et redémarré (restart)
  → But : détecter les deadlocks, processus bloqués

readinessProbe :
  "L'application est-elle prête à recevoir du trafic ?"
  → Vérification continue après le démarrage
  → Si échoue : le pod est retiré du Service (plus de trafic)
  → Le pod n'est PAS tué — il reste Running mais pas Ready
  → But : maintenance, dépendance indisponible
```

---

## Prérequis

> Ce lab suppose que le Lab 1 est terminé :
>
> - Cluster AKS fonctionnel
> - Variables `$RG` et `$CLUSTER_NAME` définies
> - `kubectl` configuré

```bash
kubectl get nodes
```

---

## Étape 0 — Variables d'environnement

```bash
source ~/.lab1-env 2>/dev/null || true
export NAMESPACE="lab-hpa"

echo "Cluster   : $CLUSTER_NAME"
echo "Namespace : $NAMESPACE"
```

```bash
kubectl create namespace $NAMESPACE
```

---

# PARTIE A — Probes : health checks des pods

## Étape 1 — Déployer un pod avec les 3 probes

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: probes-demo
  namespace: $NAMESPACE
  labels:
    app: probes-demo
spec:
  containers:
  - name: nginx
    image: nginx:alpine
    ports:
    - containerPort: 80
    # startupProbe : vérifie que nginx a démarré
    startupProbe:
      httpGet:
        path: /
        port: 80
      failureThreshold: 3       # 3 échecs avant de tuer le pod
      periodSeconds: 5           # vérifie toutes les 5s
    # livenessProbe : vérifie que nginx est toujours vivant
    livenessProbe:
      httpGet:
        path: /
        port: 80
      initialDelaySeconds: 0     # commence immédiatement (après startupProbe)
      periodSeconds: 10          # vérifie toutes les 10s
      failureThreshold: 3       # 3 échecs → redémarrage
    # readinessProbe : vérifie que nginx est prêt pour le trafic
    readinessProbe:
      httpGet:
        path: /
        port: 80
      periodSeconds: 5
      failureThreshold: 2       # 2 échecs → retiré du Service
    resources:
      requests: { cpu: "25m", memory: "32Mi" }
      limits:   { cpu: "50m", memory: "64Mi" }
EOF
```

```bash
# Attendre que le pod soit Ready
kubectl get pod probes-demo -n $NAMESPACE -w
```

**Output attendu :**

```
NAME          READY   STATUS    RESTARTS   AGE
probes-demo   1/1     Running   0          10s
```

## Étape 2 — Observer les probes

```bash
kubectl describe pod probes-demo -n $NAMESPACE | grep -A2 "Liveness\|Readiness\|Startup"
```

**Output attendu :**

```
    Liveness:       http-get http://:80/ delay=0s timeout=1s period=10s #success=1 #failure=3
    Readiness:      http-get http://:80/ delay=0s timeout=1s period=5s #success=1 #failure=2
    Startup:        http-get http://:80/ delay=0s timeout=1s period=5s #success=1 #failure=3
```

> | Paramètre | Signification |
> |-----------|---------------|
> | `delay` | `initialDelaySeconds` — attente avant la première vérification |
> | `timeout` | Temps max pour une réponse (défaut 1s) |
> | `period` | Intervalle entre deux vérifications |
> | `#success` | Nombre de succès consécutifs pour considérer OK |
> | `#failure` | Nombre d'échecs consécutifs avant d'agir |

```bash
# Nettoyer
kubectl delete pod probes-demo -n $NAMESPACE
```

---

## Étape 3 — Test de rupture : livenessProbe qui échoue

On crée un pod dont la liveness pointe vers un endpoint qui n'existe pas.

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: liveness-fail
  namespace: $NAMESPACE
spec:
  containers:
  - name: nginx
    image: nginx:alpine
    livenessProbe:
      httpGet:
        path: /healthz        # ← cet endpoint n'existe pas dans nginx
        port: 80
      initialDelaySeconds: 5
      periodSeconds: 5
      failureThreshold: 3
    resources:
      requests: { cpu: "25m", memory: "32Mi" }
      limits:   { cpu: "50m", memory: "64Mi" }
EOF
```

```bash
# Observer — le pod va redémarrer en boucle
kubectl get pod liveness-fail -n $NAMESPACE -w
```

**Output attendu (après ~30s) :**

```
NAME             READY   STATUS    RESTARTS     AGE
liveness-fail    1/1     Running   0            5s
liveness-fail    1/1     Running   1 (1s ago)   25s
liveness-fail    1/1     Running   2 (1s ago)   45s
liveness-fail    0/1     CrashLoopBackOff   2   50s
```

```bash
# Voir les events
kubectl describe pod liveness-fail -n $NAMESPACE | tail -10
```

**Output attendu :**

```
Events:
  Warning  Unhealthy  ...  Liveness probe failed: HTTP probe failed with statuscode: 404
  Normal   Killing    ...  Container nginx failed liveness probe, will be restarted
```

> **Diagnostic :** la livenessProbe retourne 404 → Kubernetes tue le conteneur et le redémarre. Après plusieurs échecs, le pod passe en `CrashLoopBackOff` (backoff exponentiel entre les redémarrages).
>
> **Leçon :** la livenessProbe doit pointer vers un endpoint qui retourne 200 quand l'app est vivante. Si l'endpoint n'existe pas, le pod redémarre indéfiniment.

```bash
kubectl delete pod liveness-fail -n $NAMESPACE
```

---

## Étape 4 — Test de rupture : readinessProbe qui échoue

Le pod reste Running mais n'est plus Ready → retiré du Service.

```bash
# Créer un Service + Deployment
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: readiness-demo
  namespace: $NAMESPACE
spec:
  replicas: 2
  selector:
    matchLabels:
      app: readiness-demo
  template:
    metadata:
      labels:
        app: readiness-demo
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
        readinessProbe:
          exec:
            command:
            - cat
            - /tmp/ready          # ← le fichier doit exister pour être "Ready"
          periodSeconds: 5
          failureThreshold: 2
        resources:
          requests: { cpu: "25m", memory: "32Mi" }
          limits:   { cpu: "50m", memory: "64Mi" }
---
apiVersion: v1
kind: Service
metadata:
  name: readiness-svc
  namespace: $NAMESPACE
spec:
  selector:
    app: readiness-demo
  ports:
  - port: 80
EOF
```

```bash
# Les pods sont Running mais pas Ready (0/1)
kubectl get pods -n $NAMESPACE -l app=readiness-demo
```

**Output attendu :**

```
NAME                              READY   STATUS    RESTARTS   AGE
readiness-demo-xxxxxxxxx-xxxxx    0/1     Running   0          10s
readiness-demo-xxxxxxxxx-xxxxx    0/1     Running   0          10s
```

```bash
# Le Service n'a aucun endpoint (aucun pod Ready)
kubectl get endpoints readiness-svc -n $NAMESPACE
```

**Output attendu :**

```
NAME            ENDPOINTS   AGE
readiness-svc   <none>      15s
```

```bash
# Rendre un pod "ready" en créant le fichier
POD1=$(kubectl get pods -n $NAMESPACE -l app=readiness-demo -o jsonpath='{.items[0].metadata.name}')
kubectl exec $POD1 -n $NAMESPACE -- touch /tmp/ready

# Attendre 5-10s puis vérifier
sleep 10
kubectl get pods -n $NAMESPACE -l app=readiness-demo
kubectl get endpoints readiness-svc -n $NAMESPACE
```

**Output attendu :**

```
NAME                              READY   STATUS    RESTARTS   AGE
readiness-demo-xxxxxxxxx-xxxxx    1/1     Running   0          30s    ← Ready
readiness-demo-xxxxxxxxx-xxxxx    0/1     Running   0          30s    ← pas Ready

NAME            ENDPOINTS        AGE
readiness-svc   10.244.x.x:80   30s    ← seulement 1 endpoint
```

> **Diagnostic :** le pod sans `/tmp/ready` est Running mais **pas Ready** (0/1). Le Service ne lui envoie pas de trafic. Le pod n'est PAS tué (contrairement à liveness) — il attend juste d'être prêt.
>
> **Cas d'usage réel :** une app qui attend que sa base de données soit disponible avant d'accepter du trafic. La readinessProbe vérifie la connexion BDD.

```bash
kubectl delete deployment readiness-demo -n $NAMESPACE
kubectl delete service readiness-svc -n $NAMESPACE
```

---

## Étape 5 — Résumé des probes

```
Séquence temporelle :

  Pod créé
    │
    ▼
  startupProbe active (liveness/readiness désactivées)
    │
    ├── Succès → startupProbe désactivée, liveness + readiness activées
    │
    └── Échec (après failureThreshold) → pod tué et redémarré
    │
    ▼
  livenessProbe + readinessProbe actives en parallèle
    │
    ├── livenessProbe échoue → pod tué et redémarré
    │
    └── readinessProbe échoue → pod retiré du Service (pas tué)


  Résumé :

  ┌──────────────┬────────────────────┬───────────────────────┐
  │ Probe        │ Si échoue          │ Le pod est...         │
  ├──────────────┼────────────────────┼───────────────────────┤
  │ startup      │ Pod tué + restart  │ Considéré "pas lancé" │
  │ liveness     │ Pod tué + restart  │ Considéré "mort"      │
  │ readiness    │ Retiré du Service  │ Running mais pas Ready│
  └──────────────┴────────────────────┴───────────────────────┘
```

---

# PARTIE B — Resource Requests, Limits & QoS

> **Avant de commencer :** s'assurer que les pods de la Partie A sont nettoyés.

## Étape 6 — Les 3 classes QoS

Kubernetes attribue une classe QoS (Quality of Service) à chaque pod selon ses requests/limits.

```bash
# Pod Guaranteed : requests = limits
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: qos-guaranteed
  namespace: $NAMESPACE
  labels:
    qos: guaranteed
spec:
  containers:
  - name: app
    image: busybox:latest
    command: ["sleep", "3600"]
    resources:
      requests: { cpu: "50m", memory: "64Mi" }
      limits:   { cpu: "50m", memory: "64Mi" }   # requests = limits
EOF

# Pod Burstable : requests < limits
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: qos-burstable
  namespace: $NAMESPACE
  labels:
    qos: burstable
spec:
  containers:
  - name: app
    image: busybox:latest
    command: ["sleep", "3600"]
    resources:
      requests: { cpu: "25m", memory: "32Mi" }
      limits:   { cpu: "100m", memory: "128Mi" }  # limits > requests
EOF

# Pod BestEffort : pas de requests ni limits
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: qos-besteffort
  namespace: $NAMESPACE
  labels:
    qos: besteffort
spec:
  containers:
  - name: app
    image: busybox:latest
    command: ["sleep", "3600"]
EOF
```

## Étape 7 — Vérifier les classes QoS

```bash
kubectl get pods -n $NAMESPACE -l qos \
  -o custom-columns=NAME:.metadata.name,QOS:.status.qosClass,STATUS:.status.phase
```

**Output attendu :**

```
NAME             QOS          STATUS
qos-besteffort   BestEffort   Running
qos-burstable    Burstable    Running
qos-guaranteed   Guaranteed   Running
```

> **Importance du QoS :** quand le nœud manque de mémoire, Kubernetes tue les pods dans cet ordre :
>
> ```
> 1. BestEffort  → tué en premier (aucune garantie)
> 2. Burstable   → tué ensuite (si usage > requests)
> 3. Guaranteed  → tué en dernier (protégé)
> ```
>
> **Recommandation production :** toujours définir requests ET limits pour obtenir au minimum `Burstable`. Les workloads critiques doivent être `Guaranteed` (requests = limits).

```bash
# Nettoyer les pods QoS
kubectl delete pod qos-guaranteed qos-burstable qos-besteffort -n $NAMESPACE
```

---

## Étape 8 — LimitRange : valeurs par défaut

Un LimitRange définit des valeurs par défaut et des limites min/max pour les pods d'un namespace.

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
  namespace: $NAMESPACE
spec:
  limits:
  - type: Container
    default:          # Limits par défaut (si non spécifiées)
      cpu: "100m"
      memory: "128Mi"
    defaultRequest:   # Requests par défaut (si non spécifiées)
      cpu: "25m"
      memory: "32Mi"
    max:              # Maximum autorisé
      cpu: "500m"
      memory: "512Mi"
    min:              # Minimum autorisé
      cpu: "10m"
      memory: "16Mi"
EOF
```

```bash
kubectl describe limitrange default-limits -n $NAMESPACE
```

**Output attendu :**

```
Type        Resource  Min   Max    Default Request  Default Limit
----        --------  ---   ---    ---------------  -------------
Container   cpu       10m   500m   25m              100m
Container   memory    16Mi  512Mi  32Mi             128Mi
```

---

## Étape 9 — Pod sans resources → LimitRange applique les defaults

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: pod-no-resources
  namespace: $NAMESPACE
spec:
  containers:
  - name: app
    image: busybox:latest
    command: ["sleep", "3600"]
    # Pas de resources spécifiées !
EOF
```

```bash
# Vérifier que le LimitRange a injecté des valeurs
kubectl get pod pod-no-resources -n $NAMESPACE -o jsonpath='{.spec.containers[0].resources}' | python3 -m json.tool
```

**Output attendu :**

```json
{
    "limits": {
        "cpu": "100m",
        "memory": "128Mi"
    },
    "requests": {
        "cpu": "25m",
        "memory": "32Mi"
    }
}
```

> Le pod n'a déclaré aucune resource, mais le LimitRange a automatiquement injecté les valeurs par défaut. C'est un filet de sécurité : aucun pod ne peut tourner sans limites dans ce namespace.

```bash
kubectl delete pod pod-no-resources -n $NAMESPACE
```

---

## Étape 10 — Test de rupture : OOMKilled

```bash
# Pod qui essaie d'utiliser plus de mémoire que sa limit
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: oom-demo
  namespace: $NAMESPACE
spec:
  containers:
  - name: stress
    image: busybox:latest
    command: ["/bin/sh", "-c"]
    args:
    - |
      echo "Allocation de mémoire au-delà de la limit (64Mi)..."
      # Créer un fichier de 100Mi en mémoire (tmpfs)
      dd if=/dev/zero of=/dev/shm/bigfile bs=1M count=100
      sleep 3600
    resources:
      requests: { cpu: "25m", memory: "32Mi" }
      limits:   { cpu: "50m", memory: "64Mi" }   # ← limit à 64Mi
EOF
```

```bash
# Attendre ~10s puis observer
sleep 10
kubectl get pod oom-demo -n $NAMESPACE
```

**Output attendu :**

```
NAME       READY   STATUS      RESTARTS     AGE
oom-demo   0/1     OOMKilled   1 (5s ago)   15s
```

```bash
kubectl describe pod oom-demo -n $NAMESPACE | grep -A3 "Last State"
```

**Output attendu :**

```
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
```

> **Diagnostic :** le conteneur a tenté d'utiliser plus de 64Mi de mémoire. Le kernel Linux (via cgroups) a tué le processus (signal 9 = exit code 137). Le pod est redémarré automatiquement.
>
> **Exit code 137 :** 128 + 9 (signal SIGKILL). Toujours signe d'un OOMKill.

```bash
kubectl delete pod oom-demo -n $NAMESPACE
```

---

## Étape 11 — ResourceQuota : limiter un namespace

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ns-quota
  namespace: $NAMESPACE
spec:
  hard:
    pods: "6"                    # Max 6 pods dans ce namespace
    requests.cpu: "500m"         # Total requests CPU max
    requests.memory: "512Mi"     # Total requests mémoire max
    limits.cpu: "1"              # Total limits CPU max
    limits.memory: "1Gi"         # Total limits mémoire max
EOF
```

```bash
kubectl describe resourcequota ns-quota -n $NAMESPACE
```

**Output attendu :**

```
Name:            ns-quota
Namespace:       lab-hpa
Resource         Used  Hard
--------         ----  ----
limits.cpu       0     1
limits.memory    0     1Gi
pods             0     6
requests.cpu     0     500m
requests.memory  0     512Mi
```

---

## Étape 12 — Test de rupture : dépasser le quota

```bash
# Créer un Deployment qui va dépasser le quota de pods
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: quota-test
  namespace: $NAMESPACE
spec:
  replicas: 8                    # ← 8 pods demandés mais quota = 6 max
  selector:
    matchLabels:
      app: quota-test
  template:
    metadata:
      labels:
        app: quota-test
    spec:
      containers:
      - name: app
        image: busybox:latest
        command: ["sleep", "3600"]
        resources:
          requests: { cpu: "25m", memory: "32Mi" }
          limits:   { cpu: "50m", memory: "64Mi" }
EOF
```

```bash
# Observer — certains pods ne seront pas créés
sleep 5
kubectl get pods -n $NAMESPACE -l app=quota-test
kubectl get deployment quota-test -n $NAMESPACE
```

**Output attendu :**

```
NAME                          READY   STATUS    RESTARTS   AGE
quota-test-xxxxxxxxx-xxxxx    1/1     Running   0          5s
quota-test-xxxxxxxxx-xxxxx    1/1     Running   0          5s
quota-test-xxxxxxxxx-xxxxx    1/1     Running   0          5s
quota-test-xxxxxxxxx-xxxxx    1/1     Running   0          5s
quota-test-xxxxxxxxx-xxxxx    1/1     Running   0          5s
quota-test-xxxxxxxxx-xxxxx    1/1     Running   0          5s

NAME         READY   UP-TO-DATE   AVAILABLE   AGE
quota-test   6/8     6            6           10s
```

```bash
# Voir l'événement de refus
kubectl describe deployment quota-test -n $NAMESPACE | tail -5
```

**Output attendu :**

```
  Warning  FailedCreate  ...  replicaset-controller  Error creating: pods "quota-test-xxxxx"
  is forbidden: exceeded quota: ns-quota, requested: pods=1, used: pods=6, limited: pods=6
```

```bash
# Voir l'utilisation du quota
kubectl describe resourcequota ns-quota -n $NAMESPACE
```

> **Diagnostic :** le Deployment veut 8 réplicas mais le quota limite à 6 pods. Les 2 derniers sont refusés. Le Deployment reste à 6/8 (pas une erreur bloquante, il réessaie en continu).

```bash
kubectl delete deployment quota-test -n $NAMESPACE
```

---

# PARTIE C — HPA : autoscaling horizontal

> **Avant de commencer :** nettoyer les ressources de la Partie B (sauf le ResourceQuota et LimitRange qu'on garde).

## Étape 13 — Vérifier metrics-server

Le HPA a besoin de metrics-server pour connaître l'utilisation CPU/mémoire des pods.

```bash
# Vérifier que metrics-server est installé (installé par défaut sur AKS)
kubectl get deployment metrics-server -n kube-system
```

**Output attendu :**

```
NAME             READY   UP-TO-DATE   AVAILABLE   AGE
metrics-server   1/1     1            1           ...
```

```bash
# Vérifier qu'il retourne des métriques
kubectl top nodes
kubectl top pods -n kube-system
```

> Si `kubectl top` retourne une erreur, attendre 1-2 minutes — metrics-server a besoin de temps pour collecter les premières métriques.

---

## Étape 14 — Déployer l'application à scaler

```bash
# Supprimer le ResourceQuota pour ne pas bloquer le HPA
kubectl delete resourcequota ns-quota -n $NAMESPACE

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: php-apache
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: php-apache
  template:
    metadata:
      labels:
        app: php-apache
    spec:
      containers:
      - name: php-apache
        image: registry.k8s.io/hpa-example
        ports:
        - containerPort: 80
        readinessProbe:
          httpGet:
            path: /
            port: 80
          periodSeconds: 5
        resources:
          requests: { cpu: "100m", memory: "64Mi" }   # ← le HPA calcule le % par rapport à ce request
          limits:   { cpu: "200m", memory: "128Mi" }
---
apiVersion: v1
kind: Service
metadata:
  name: php-apache
  namespace: $NAMESPACE
spec:
  selector:
    app: php-apache
  ports:
  - port: 80
EOF
```

```bash
kubectl get pods -n $NAMESPACE -l app=php-apache
```

> L'image `registry.k8s.io/hpa-example` est un serveur PHP qui effectue un calcul CPU intensif à chaque requête. Elle est conçue pour tester le HPA.

---

## Étape 15 — Créer le HPA

```bash
cat <<EOF | kubectl apply -f -
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: hpa-php-apache
  namespace: $NAMESPACE
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: php-apache
  minReplicas: 1               # Minimum 1 pod
  maxReplicas: 5               # Maximum 5 pods
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50  # Scale-up si CPU moyen > 50% des requests
EOF
```

```bash
kubectl get hpa -n $NAMESPACE
```

**Output attendu :**

```
NAME             REFERENCE               TARGETS   MINPODS   MAXPODS   REPLICAS   AGE
hpa-php-apache   Deployment/php-apache   0%/50%    1         5         1          10s
```

> | Colonne | Signification |
> |---------|---------------|
> | `TARGETS` | `usage actuel%` / `target%` — ici 0% utilisé, cible 50% |
> | `MINPODS` | Nombre minimum de pods (jamais en dessous) |
> | `MAXPODS` | Nombre maximum de pods (jamais au-dessus) |
> | `REPLICAS` | Nombre actuel de pods |

> **Comment le HPA calcule :**
> ```
> ratio = usage CPU moyen / request CPU = usage / 100m
> Si ratio > 50% → scale-up
> Si ratio < 50% → scale-down (après cooldown de 5 min)
>
> Nombre de réplicas souhaité = ceil(réplicas actuels × ratio / target)
> Exemple : 1 pod à 90% CPU → ceil(1 × 90 / 50) = ceil(1.8) = 2 réplicas
> ```

---

## Étape 16 — Générer de la charge → scale-up

```bash
# Lancer un pod de charge dans un autre terminal (ou en background)
kubectl run load-generator -n $NAMESPACE \
  --image=busybox:latest \
  --restart=Never \
  -- /bin/sh -c "while true; do wget -q -O- http://php-apache; done"
```

```bash
# Observer le HPA (lancer dans un autre terminal ou attendre 1-2 min)
kubectl get hpa -n $NAMESPACE -w
```

**Output attendu (après 1-2 minutes) :**

```
NAME             REFERENCE               TARGETS    MINPODS   MAXPODS   REPLICAS   AGE
hpa-php-apache   Deployment/php-apache   0%/50%     1         5         1          30s
hpa-php-apache   Deployment/php-apache   95%/50%    1         5         1          60s
hpa-php-apache   Deployment/php-apache   95%/50%    1         5         2          90s
hpa-php-apache   Deployment/php-apache   68%/50%    1         5         3          120s
hpa-php-apache   Deployment/php-apache   45%/50%    1         5         3          150s
```

```bash
# Voir les pods créés
kubectl get pods -n $NAMESPACE -l app=php-apache
```

**Output attendu :**

```
NAME                          READY   STATUS    RESTARTS   AGE
php-apache-xxxxxxxxx-xxxxx    1/1     Running   0          3m
php-apache-xxxxxxxxx-xxxxx    1/1     Running   0          90s
php-apache-xxxxxxxxx-xxxxx    1/1     Running   0          60s
```

> Le HPA a détecté que le CPU dépassait 50% des requests → il a augmenté le nombre de réplicas progressivement jusqu'à ce que l'utilisation moyenne redescende sous la cible.

---

## Étape 17 — Arrêter la charge → scale-down

```bash
# Arrêter le générateur de charge
kubectl delete pod load-generator -n $NAMESPACE
```

```bash
# Observer le scale-down (patience : cooldown de ~5 minutes)
kubectl get hpa -n $NAMESPACE -w
```

**Output attendu (après ~5 minutes) :**

```
NAME             REFERENCE               TARGETS   MINPODS   MAXPODS   REPLICAS   AGE
hpa-php-apache   Deployment/php-apache   45%/50%   1         5         3          5m
hpa-php-apache   Deployment/php-apache   0%/50%    1         5         3          6m
hpa-php-apache   Deployment/php-apache   0%/50%    1         5         1          10m
```

> Le scale-down est **volontairement lent** (stabilization window de 5 min par défaut). Cela évite le "flapping" (scale-up/down en boucle) lors de pics de charge intermittents.

---

## Étape 18 — Observer le HPA en détail

```bash
kubectl describe hpa hpa-php-apache -n $NAMESPACE
```

**Output attendu :**

```
Name:                        hpa-php-apache
Namespace:                   lab-hpa
Reference:                   Deployment/php-apache
Metrics:                     ( current / target )
  resource cpu on pods:      0% (1m) / 50%
Min replicas:                1
Max replicas:                5
Deployment pods:             1 current / 1 desired
Events:
  Normal  SuccessfulRescale  ...  New size: 2; reason: cpu resource utilization above target
  Normal  SuccessfulRescale  ...  New size: 3; reason: cpu resource utilization above target
  Normal  SuccessfulRescale  ...  New size: 1; reason: All metrics below target
```

> Les events montrent chaque décision de scaling avec la raison. Utile pour le debug.

---

## Étape 19 — Test de rupture : HPA sans requests

```bash
# Déployer un Deployment SANS resource requests
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: no-requests
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: no-requests
  template:
    metadata:
      labels:
        app: no-requests
    spec:
      containers:
      - name: app
        image: nginx:alpine
EOF

# Créer un HPA dessus
kubectl autoscale deployment no-requests -n $NAMESPACE \
  --min=1 --max=3 --cpu-percent=50
```

```bash
kubectl get hpa -n $NAMESPACE
```

**Output attendu :**

```
NAME           REFERENCE              TARGETS         MINPODS   MAXPODS   REPLICAS   AGE
no-requests    Deployment/no-requests <unknown>/50%   1         3         1          10s
```

> **Diagnostic :** `TARGETS` affiche `<unknown>/50%`. Le HPA ne peut pas calculer le pourcentage d'utilisation CPU car le Deployment n'a pas de `resources.requests.cpu`. Sans request, le HPA ne sait pas "50% de quoi ?".
>
> **Leçon :** `resources.requests` est **obligatoire** pour que le HPA fonctionne avec des métriques de type `Utilization`.

```bash
# Nettoyer
kubectl delete hpa no-requests -n $NAMESPACE
kubectl delete deployment no-requests -n $NAMESPACE
```

---

## Étape 20 — HPA + ResourceQuota

```bash
# Recréer un quota strict
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ns-quota
  namespace: $NAMESPACE
spec:
  hard:
    pods: "3"
    requests.cpu: "300m"
EOF

# Vérifier : le HPA veut scaler à 5 max, mais le quota limite à 3 pods
kubectl get hpa -n $NAMESPACE
kubectl describe resourcequota ns-quota -n $NAMESPACE
```

```bash
# Relancer la charge
kubectl run load-generator -n $NAMESPACE \
  --image=busybox:latest \
  --restart=Never \
  -- /bin/sh -c "while true; do wget -q -O- http://php-apache; done"

# Observer — le HPA va plafonner à cause du quota
sleep 120
kubectl get hpa -n $NAMESPACE
kubectl get pods -n $NAMESPACE -l app=php-apache
```

> Le HPA essaie de créer plus de pods, mais le ResourceQuota bloque au-delà de 3 pods (ou 300m CPU total). Les events du Deployment montrent `exceeded quota`.

```bash
# Nettoyer
kubectl delete pod load-generator -n $NAMESPACE
kubectl delete resourcequota ns-quota -n $NAMESPACE
kubectl delete hpa hpa-php-apache -n $NAMESPACE
kubectl delete deployment php-apache -n $NAMESPACE
kubectl delete service php-apache -n $NAMESPACE
```

---

# PARTIE D — Jobs & CronJobs

> **Avant de commencer :** s'assurer que les pods des parties précédentes sont nettoyés.

## Étape 21 — Job simple

Un Job exécute une tâche puis se termine (contrairement à un Deployment qui tourne en continu).

```bash
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: calcul-pi
  namespace: $NAMESPACE
spec:
  template:
    spec:
      containers:
      - name: pi
        image: busybox:latest
        command: ["/bin/sh", "-c"]
        args:
        - |
          echo "Calcul de Pi avec 2000 décimales..."
          echo "scale=2000; 4*a(1)" | bc -l
          echo "Terminé."
        resources:
          requests: { cpu: "50m", memory: "32Mi" }
          limits:   { cpu: "100m", memory: "64Mi" }
      restartPolicy: Never       # ← obligatoire pour un Job
  backoffLimit: 3                # ← nombre de tentatives en cas d'échec
EOF
```

```bash
# Observer le cycle de vie
kubectl get job calcul-pi -n $NAMESPACE -w
```

**Output attendu :**

```
NAME        STATUS      COMPLETIONS   DURATION   AGE
calcul-pi   Running     0/1           5s         5s
calcul-pi   Complete    1/1           12s        12s
```

```bash
# Voir le résultat (les dernières lignes de Pi)
kubectl logs job/calcul-pi -n $NAMESPACE | tail -3
```

> Le pod passe de `Running` à `Completed`. Il n'est pas supprimé (on peut lire ses logs), mais il ne consomme plus de ressources.

---

## Étape 22 — Job parallèle

```bash
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: batch-process
  namespace: $NAMESPACE
spec:
  completions: 5          # 5 exécutions au total
  parallelism: 2          # 2 pods en parallèle max
  template:
    spec:
      containers:
      - name: worker
        image: busybox:latest
        command: ["/bin/sh", "-c"]
        args:
        - |
          TASK_ID=$RANDOM
          echo "Worker $HOSTNAME traite la tâche $TASK_ID"
          sleep $((RANDOM % 10 + 5))
          echo "Tâche $TASK_ID terminée"
        resources:
          requests: { cpu: "25m", memory: "16Mi" }
          limits:   { cpu: "50m", memory: "32Mi" }
      restartPolicy: Never
  backoffLimit: 3
EOF
```

```bash
# Observer les pods créés par vagues de 2
kubectl get pods -n $NAMESPACE -l job-name=batch-process -w
```

**Output attendu (au fil du temps) :**

```
batch-process-xxxxx   1/1     Running     0   0s
batch-process-yyyyy   1/1     Running     0   0s     ← 2 en parallèle
batch-process-xxxxx   0/1     Completed   0   8s
batch-process-zzzzz   1/1     Running     0   0s     ← un 3ème démarre
batch-process-yyyyy   0/1     Completed   0   12s
batch-process-wwwww   1/1     Running     0   0s     ← un 4ème démarre
...
```

```bash
kubectl get job batch-process -n $NAMESPACE
```

**Output attendu :**

```
NAME            STATUS     COMPLETIONS   DURATION   AGE
batch-process   Complete   5/5           35s        40s
```

> `completions: 5` signifie que 5 pods doivent se terminer avec succès. `parallelism: 2` signifie que 2 pods tournent en même temps max. Kubernetes lance les pods par vagues.

---

## Étape 23 — CronJob

```bash
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: CronJob
metadata:
  name: health-check
  namespace: $NAMESPACE
spec:
  schedule: "*/2 * * * *"       # Toutes les 2 minutes
  successfulJobsHistoryLimit: 3  # Garder les 3 derniers Jobs réussis
  failedJobsHistoryLimit: 2      # Garder les 2 derniers Jobs échoués
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: check
            image: busybox:latest
            command: ["/bin/sh", "-c"]
            args:
            - |
              echo "[$(date)] Health check démarré"
              echo "Vérification des services..."
              echo "[$(date)] Health check OK"
            resources:
              requests: { cpu: "10m", memory: "16Mi" }
              limits:   { cpu: "25m", memory: "32Mi" }
          restartPolicy: Never
EOF
```

```bash
kubectl get cronjob -n $NAMESPACE
```

**Output attendu :**

```
NAME           SCHEDULE      TIMEZONE   SUSPEND   ACTIVE   LAST SCHEDULE   AGE
health-check   */2 * * * *   <none>     False     0        <none>          10s
```

```bash
# Attendre ~2 min pour la première exécution puis observer
sleep 130
kubectl get jobs -n $NAMESPACE -l job-name
kubectl get pods -n $NAMESPACE --sort-by=.metadata.creationTimestamp
```

**Output attendu :**

```
NAME                          STATUS     COMPLETIONS   DURATION   AGE
health-check-28612345         Complete   1/1           3s         2m
```

```bash
# Voir les logs de la dernière exécution
kubectl logs job/$(kubectl get jobs -n $NAMESPACE -l job-name -o jsonpath='{.items[-1].metadata.name}') -n $NAMESPACE
```

**Output attendu :**

```
[Thu May 21 10:30:00 UTC 2026] Health check démarré
Vérification des services...
[Thu May 21 10:30:00 UTC 2026] Health check OK
```

> **Format cron :** `*/2 * * * *` = toutes les 2 minutes.
>
> ```
> ┌───────────── minute (0-59)
> │ ┌───────────── heure (0-23)
> │ │ ┌───────────── jour du mois (1-31)
> │ │ │ ┌───────────── mois (1-12)
> │ │ │ │ ┌───────────── jour de la semaine (0-6, 0=dimanche)
> │ │ │ │ │
> */2 * * * *
> ```

---

## Étape 24 — Test de rupture : Job qui échoue

```bash
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: job-fail
  namespace: $NAMESPACE
spec:
  backoffLimit: 3              # 3 tentatives max
  template:
    spec:
      containers:
      - name: fail
        image: busybox:latest
        command: ["/bin/sh", "-c"]
        args:
        - |
          echo "Tentative de connexion à la BDD..."
          echo "ERREUR: connexion refusée"
          exit 1               # ← simule un échec
        resources:
          requests: { cpu: "10m", memory: "16Mi" }
          limits:   { cpu: "25m", memory: "32Mi" }
      restartPolicy: Never
EOF
```

```bash
# Observer les tentatives (backoff exponentiel)
kubectl get pods -n $NAMESPACE -l job-name=job-fail -w
```

**Output attendu :**

```
job-fail-xxxxx   0/1     Completed   0   3s     ← tentative 1 (exit 1 = échec)
job-fail-yyyyy   0/1     Completed   0   15s    ← tentative 2 (après 10s backoff)
job-fail-zzzzz   0/1     Completed   0   35s    ← tentative 3 (après 20s backoff)
job-fail-wwwww   0/1     Completed   0   75s    ← tentative 4 (après 40s backoff)
```

```bash
kubectl get job job-fail -n $NAMESPACE
```

**Output attendu :**

```
NAME       STATUS   COMPLETIONS   DURATION   AGE
job-fail   Failed   0/1           80s        90s
```

> **Diagnostic :** le Job a échoué 4 fois (1 initial + 3 backoffLimit). Kubernetes a appliqué un backoff exponentiel entre les tentatives (10s, 20s, 40s). Après `backoffLimit` échecs, le Job passe à `Failed` et ne réessaie plus.

---

## Nettoyage des ressources

```bash
# Supprimer le namespace (supprime tout)
kubectl delete namespace $NAMESPACE
```

---

## Récapitulatif des concepts vus

| Concept | Ce que vous avez fait |
|---|---|
| livenessProbe | Vérifier qu'un conteneur est vivant — redémarrage si échec |
| readinessProbe | Vérifier qu'un pod est prêt — retiré du Service si échec |
| startupProbe | Vérifier le démarrage initial — protège les apps lentes |
| QoS Guaranteed | requests = limits → derniers tués en cas de pression mémoire |
| QoS Burstable | requests < limits → tués après BestEffort |
| QoS BestEffort | pas de resources → tués en premier |
| LimitRange | Valeurs par défaut + min/max pour un namespace |
| ResourceQuota | Limiter le total de ressources d'un namespace |
| OOMKilled | Le kernel tue un conteneur qui dépasse sa memory limit |
| HPA | Scale automatique basé sur l'utilisation CPU (ou custom metrics) |
| Scale-up / scale-down | Le HPA ajuste les réplicas avec un cooldown de 5 min |
| Job | Tâche ponctuelle qui se termine (batch processing) |
| CronJob | Tâche planifiée récurrente (cron) |
| backoffLimit | Nombre de tentatives avant d'abandonner un Job |

---

## Questions de vérification

1. Un pod a 0 restart mais son READY est 0/1. Quelle probe est probablement en échec : liveness ou readiness ? Quel est l'impact sur le trafic ?
2. Un Deployment a `requests.cpu: 100m` et `limits.cpu: 200m`. Quelle est la classe QoS ? Que se passe-t-il si le pod utilise 150m de CPU ?
3. Un HPA affiche `TARGETS: <unknown>/50%`. Quelle est la cause ? Comment corriger ?
4. Le HPA est configuré avec `maxReplicas: 10` mais ne dépasse jamais 4 pods. Citez 2 raisons possibles.
5. Un Job avec `completions: 10` et `parallelism: 3` — combien de pods tournent en même temps ? Combien de vagues sont nécessaires ?
6. Pourquoi le scale-down du HPA prend 5 minutes ? Que se passerait-il sans ce délai ?

---

## Pour aller plus loin

- **VPA (Vertical Pod Autoscaler)** : ajuste automatiquement les requests/limits au lieu du nombre de réplicas. Utile quand on ne sait pas combien de CPU/mémoire un pod a besoin. Ne pas combiner VPA et HPA sur la même métrique (CPU).
- **KEDA (Kubernetes Event-Driven Autoscaler)** : scale basé sur des métriques externes (longueur de queue Azure Service Bus, messages Kafka, requêtes HTTP). Plus flexible que le HPA natif.
- **Cluster Autoscaler** : scale les **nœuds** (pas les pods). Quand le HPA crée des pods mais qu'il n'y a pas assez de ressources sur les nœuds → le Cluster Autoscaler ajoute des nœuds au node pool.
- **HPA sur custom metrics** : scaler sur des métriques applicatives (requêtes/seconde, latence P99, connexions actives) via Prometheus Adapter ou Azure Monitor.
- **PriorityClass** : définir des priorités entre pods. En cas de pression sur les ressources, les pods de basse priorité sont évincés en faveur des pods de haute priorité.
- **Init Containers** : conteneurs qui s'exécutent **avant** le conteneur principal. Utilisés pour : attendre qu'une dépendance soit prête, télécharger des fichiers de config, appliquer des migrations BDD.
