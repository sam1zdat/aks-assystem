# LAB 2 — Ingress & routage L7

> Exposer plusieurs services via un seul point d'entrée grâce à un Ingress Controller nginx avec path-based routing.
> Durée estimée : 30 min · Niveau : Intermédiaire

---

## Prérequis

L'infrastructure a été préparée par `lab2-infra-setup.sh`. Chargez les variables :

```bash
source ~/.lab1-env
source ~/.lab2-env
```

Ce fichier contient :

```bash
export NAMESPACE_INGRESS="lab-ingress"       # Namespace du lab
export INGRESS_IP="20.111.55.200"            # IP publique du contrôleur Ingress
```

Vérification :

```bash
kubectl get pods -n ingress-nginx            # 1 pod Running
echo "Ingress IP : $INGRESS_IP"              # doit afficher une IP
```

---

## Contexte

Sans Ingress, chaque service nécessite son propre `LoadBalancer` Azure — une IP publique facturée ~18€/mois chacun. Avec un seul Ingress Controller, un seul Load Balancer route tout le trafic HTTP vers vos services selon le path ou le hostname.

```
Internet
    │
    └─ IP publique unique (Azure Load Balancer)
           │
    Ingress Controller (nginx)
           │
    ┌──────┴──────┐
    │             │
  /app1        /app2
    │             │
Service app-v1  Service app-v2
    │             │
[Pod app-v1]  [Pod app-v2]
```

---

## Étape 1 — Déployer deux services applicatifs

On déploie deux applications nginx avec des pages différentes pour vérifier le routage.

### 1.1 Déployer app-v1

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-v1-html
  namespace: $NAMESPACE_INGRESS
data:
  index.html: |
    Réponse de APP-V1 - chemin /app1
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-v1
  namespace: $NAMESPACE_INGRESS
spec:
  replicas: 1
  selector:
    matchLabels:
      app: app-v1
  template:
    metadata:
      labels:
        app: app-v1
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
        volumeMounts:
        - name: html
          mountPath: /usr/share/nginx/html
        resources:
          requests: { cpu: "50m", memory: "64Mi" }
          limits:   { cpu: "100m", memory: "128Mi" }
      volumes:
      - name: html
        configMap:
          name: app-v1-html
---
apiVersion: v1
kind: Service
metadata:
  name: app-v1-svc
  namespace: $NAMESPACE_INGRESS
spec:
  selector:
    app: app-v1
  ports:
  - port: 80
    targetPort: 80
EOF
```

### 1.2 Déployer app-v2

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-v2-html
  namespace: $NAMESPACE_INGRESS
data:
  index.html: |
    Réponse de APP-V2 - chemin /app2
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-v2
  namespace: $NAMESPACE_INGRESS
spec:
  replicas: 1
  selector:
    matchLabels:
      app: app-v2
  template:
    metadata:
      labels:
        app: app-v2
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
        volumeMounts:
        - name: html
          mountPath: /usr/share/nginx/html
        resources:
          requests: { cpu: "50m", memory: "64Mi" }
          limits:   { cpu: "100m", memory: "128Mi" }
      volumes:
      - name: html
        configMap:
          name: app-v2-html
---
apiVersion: v1
kind: Service
metadata:
  name: app-v2-svc
  namespace: $NAMESPACE_INGRESS
spec:
  selector:
    app: app-v2
  ports:
  - port: 80
    targetPort: 80
EOF
```

### 1.3 Vérifier

```bash
kubectl get pods,svc -n $NAMESPACE_INGRESS
```

**Output attendu :**

```
NAME                          READY   STATUS    RESTARTS   AGE
pod/app-v1-xxxxxxxxx-xxxxx    1/1     Running   0          30s
pod/app-v2-xxxxxxxxx-xxxxx    1/1     Running   0          20s

NAME                 TYPE        CLUSTER-IP     PORT(S)   AGE
service/app-v1-svc   ClusterIP   10.0.50.10     80/TCP    30s
service/app-v2-svc   ClusterIP   10.0.50.11     80/TCP    20s
```

> ℹ️ Les services sont en `ClusterIP` — accessibles uniquement depuis l'intérieur du cluster. C'est l'Ingress Controller qui les expose publiquement. Un seul Load Balancer Azure pour tous les services.

---

## Étape 2 — Créer l'Ingress avec path-based routing

```bash
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: lab-ingress
  namespace: $NAMESPACE_INGRESS
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /app1
        pathType: Prefix
        backend:
          service:
            name: app-v1-svc
            port:
              number: 80
      - path: /app2
        pathType: Prefix
        backend:
          service:
            name: app-v2-svc
            port:
              number: 80
EOF
```

### 2.1 Vérifier la création

```bash
kubectl get ingress -n $NAMESPACE_INGRESS
kubectl describe ingress lab-ingress -n $NAMESPACE_INGRESS
```

> ⚠️ Si le champ `ADDRESS` est vide après 1 minute :
> ```bash
> kubectl get ingressclass    # doit afficher : nginx
> ```

### 2.2 Tester le routage

```bash
curl -s http://$INGRESS_IP/app1
# Output attendu : Réponse de APP-V1 - chemin /app1

curl -s http://$INGRESS_IP/app2
# Output attendu : Réponse de APP-V2 - chemin /app2

# Chemin inexistant → 404
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://$INGRESS_IP/inconnu
# Output attendu : HTTP 404
```

> ✅ Le routage L7 fonctionne — un seul Load Balancer, deux services, routage par chemin URL.

> 🛟 **Si timeout sur curl** : le probe Azure est probablement en HTTP au lieu de TCP. Vérifier :
> ```bash
> NODE_RG=$(az aks show -g $RG -n $CLUSTER_NAME --query nodeResourceGroup -o tsv)
> LB_NAME=$(az network lb list -g $NODE_RG --query "[0].name" -o tsv)
> az network lb probe list -g $NODE_RG --lb-name $LB_NAME -o table
> ```
> Si `Protocol=Http` → corriger :
> ```bash
> kubectl annotate svc ingress-nginx-controller -n ingress-nginx \
>   service.beta.kubernetes.io/port_80_health-probe_protocol=tcp --overwrite
> sleep 60
> ```

### 2.3 Inspecter les logs du contrôleur

```bash
kubectl logs -l app.kubernetes.io/name=ingress-nginx -n ingress-nginx --tail=10
```

Vous devez voir les requêtes GET /app1, /app2 et /inconnu avec les codes 200 et 404.

---

## Étape 3 — Test de rupture : backend inexistant

```bash
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ingress-broken
  namespace: $NAMESPACE_INGRESS
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /fantome
        pathType: Prefix
        backend:
          service:
            name: service-inexistant
            port:
              number: 80
EOF

curl -s -o /dev/null -w "HTTP %{http_code}\n" http://$INGRESS_IP/fantome
# Output attendu : HTTP 503
```

> ✅ **503 Service Unavailable** = nginx a la règle mais le backend est introuvable. Différent d'un 404 (pas de règle pour ce path). Utile pour le diagnostic en production.

```bash
# Nettoyer
kubectl delete ingress ingress-broken -n $NAMESPACE_INGRESS
```

---

## Récapitulatif des concepts

| Concept | Ce que vous avez fait |
|---|---|
| Ingress Controller nginx | Un seul Load Balancer pour tous les services |
| Path-based routing | `/app1` → app-v1, `/app2` → app-v2 |
| `rewrite-target` | Réécrit le path avant transmission au backend |
| `ingressClassName` | Identifie quel contrôleur gère cet Ingress |
| Service ClusterIP | Services internes, routés via l'Ingress uniquement |
| ConfigMap comme volume | Injecter du contenu dans un conteneur sans rebuild d'image |
| 503 vs 404 | 503 = backend down, 404 = pas de règle de routage |

---

## Questions de vérification

1. Quelle est la différence entre un Service `LoadBalancer` et un Service `ClusterIP` avec un Ingress ? Avantage en coût Azure ?
2. Que fait l'annotation `rewrite-target: /` ? Que se passe-t-il si on la retire ?
3. Un Ingress retourne 503 sur un path configuré — quelles causes investiguer ?
4. Pourquoi un probe HTTP `/` peut-il casser le routage public alors que le test interne au cluster fonctionne ?
5. Comment ajouter un troisième service `/app3` sans créer de nouveau Load Balancer ?

---

## Nettoyage

```bash
# Garder ingress-nginx pour les labs suivants
./lab2-cleanup.sh --k8s-only

# Ou tout supprimer (libère le Load Balancer Azure)
./lab2-cleanup.sh --full
```
