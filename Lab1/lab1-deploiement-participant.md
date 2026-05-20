# LAB 1 — Build, déploiement et diagnostic sur AKS

> Exercice pratique : builder une image, la déployer sur le cluster AKS, vérifier l'accès, tester la résilience et diagnostiquer une erreur.
> Durée estimée : 45 min · Niveau : Intermédiaire

---

## Prérequis

Chaque participant dispose d'un **Resource Group pré-assigné** par le formateur (`rg-aks-formation-N`).

### Créer l'infrastructure

Lancez le script avec votre numéro de participant (communiqué par le formateur) :

```bash
./lab1-infra-setup.sh --participant N    # remplacer N par votre numéro
```

Puis chargez les variables générées :

```bash
source ~/.lab1-env
```

Ce fichier contient :

```bash
export PARTICIPANT_NUM="3"                      # Votre numéro
export RG="rg-aks-formation-3"                  # Resource Group pré-assigné
export LOCATION="francecentral"                 # Région Azure
export CLUSTER_NAME="aks-formation-3"           # Nom du cluster AKS
export ACR_NAME="acrakslab4f2a1c"               # Nom de l'ACR (unique)
export ACR_LOGIN_SERVER="acrakslab4f2a1c.azurecr.io"  # URL du registre
export SUBSCRIPTION_ID="xxxxxxxx-xxxx-..."      # ID de l'abonnement
```

Vérification :

```bash
kubectl get nodes                # 1 nœud Ready
echo "ACR : $ACR_LOGIN_SERVER"   # doit afficher <nom>.azurecr.io
```

---

## Étape 1 — Builder une image et la pousser dans l'ACR

On crée une image nginx personnalisée avec une page HTML — utile pour visualiser le load balancing entre pods plus tard.

### 1.1 Créer les fichiers de l'application

```bash
mkdir -p ~/aks-lab-app && cd ~/aks-lab-app

cat > index.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
  <title>AKS Lab — Premier déploiement</title>
  <style>
    body { font-family: monospace; background: #0f1923; color: #e2e8f0;
           display: flex; align-items: center; justify-content: center;
           height: 100vh; margin: 0; flex-direction: column; gap: 16px; }
    h1 { color: #0078D4; font-size: 2rem; }
    .pod { background: #1e2d3d; padding: 12px 24px; border-radius: 8px;
           border: 1px solid rgba(0,120,212,0.3); font-size: 0.9rem; color: #94a3b8; }
  </style>
</head>
<body>
  <h1>Formation AKS</h1>
  <p>Premier déploiement réussi sur Azure Kubernetes Service</p>
  <div class="pod">Serveur : nginx · Déployé via ACR + AKS</div>
</body>
</html>
EOF

cat > Dockerfile << 'EOF'
FROM nginx:alpine
COPY index.html /usr/share/nginx/html/index.html
EXPOSE 80
EOF
```

### 1.2 Builder l'image dans l'ACR

```bash
# az acr build envoie le contexte Docker à Azure et build l'image directement dans l'ACR
# Avantage : pas besoin de Docker en local, pas besoin de az acr login
az acr build \
  --registry $ACR_NAME \
  --image nginx-app:v1.0 \
  --file Dockerfile \
  .
```

**Output attendu (extrait) :**

```
Queued a build with ID: ca1
...
Successfully tagged acrakslab4f2a1c.azurecr.io/nginx-app:v1.0
Run ID: ca1 was successful after 35s
```

```bash
# Vérifier que l'image est bien dans l'ACR
az acr repository show-tags --name $ACR_NAME --repository nginx-app --output table
```

> ℹ️ **`az acr build` vs `docker build` + `docker push`**
>
> `az acr build` délègue le build aux agents Azure — pas de daemon Docker nécessaire, logs centralisés dans Azure.
> `docker build` + `docker push` : approche classique, utile si vous testez l'image localement d'abord.

---

## Étape 2 — Déployer l'application sur AKS

Un **Deployment** gère le cycle de vie des pods (réplicas, rolling update, rollback). Un **Service LoadBalancer** expose les pods via une IP publique Azure.

### 2.1 Créer le Deployment

```bash
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-app
  namespace: default
  labels:
    app: nginx-app
spec:
  replicas: 2                          # 2 pods pour démontrer le load balancing
  selector:
    matchLabels:
      app: nginx-app
  template:
    metadata:
      labels:
        app: nginx-app
    spec:
      containers:
      - name: nginx
        image: ${ACR_LOGIN_SERVER}/nginx-app:v1.0
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: "100m"                # Minimum garanti : 0.1 vCPU
            memory: "128Mi"
          limits:
            cpu: "250m"                # Maximum autorisé : 0.25 vCPU
            memory: "256Mi"
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 10
EOF
```

> ℹ️ **`readinessProbe`** : Kubernetes ne route du trafic vers ce pod que quand il répond sur `/` port 80. Sans elle, le Service pourrait envoyer des requêtes à un pod encore en cours de démarrage.

### 2.2 Créer le Service LoadBalancer

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: nginx-app-svc
  namespace: default
spec:
  type: LoadBalancer
  selector:
    app: nginx-app
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
EOF
```

### 2.3 Suivre le déploiement

```bash
# Attendre que le Deployment soit prêt
kubectl rollout status deployment/nginx-app

# Vérifier les pods
kubectl get pods -l app=nginx-app -o wide
```

**Output attendu :**

```
NAME                         READY   STATUS    RESTARTS   AGE   IP            NODE
nginx-app-xxxxxxxxx-aaaaa    1/1     Running   0          45s   10.224.0.10   aks-nodepool1-...vmss000000
nginx-app-xxxxxxxxx-bbbbb    1/1     Running   0          45s   10.224.0.11   aks-nodepool1-...vmss000000
```

> Note : avec 1 nœud, les deux pods tournent sur le même nœud.

```bash
# Attendre l'IP publique (1-2 min — Azure crée le Load Balancer)
kubectl get svc nginx-app-svc --watch
# Ctrl+C quand EXTERNAL-IP apparaît

# Stocker l'IP publique
export PUBLIC_IP=$(kubectl get svc nginx-app-svc -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Application disponible sur : http://$PUBLIC_IP"
```

---

## Étape 3 — Vérifier l'accès et inspecter les ressources

### 3.1 Tester l'application

```bash
curl -s -o /dev/null -w "HTTP %{http_code} — %{time_total}s\n" http://$PUBLIC_IP

curl -s http://$PUBLIC_IP | grep "<title>"
```

Ouvrir également dans un navigateur : `http://<EXTERNAL-IP>`

> ℹ️ **Si l'IP publique est bloquée** (proxy / firewall entreprise) :
>
> ```bash
> kubectl port-forward deployment/nginx-app 8080:80
> # Ouvrir http://localhost:8080
> ```

### 3.2 Inspecter les ressources

```bash
kubectl get all -n default

kubectl describe deployment nginx-app

kubectl logs -l app=nginx-app --tail=20

# Métriques (peut nécessiter 2-3 min après création du cluster)
kubectl top pods -l app=nginx-app
```

> ℹ️ **ReplicaSet** : le Deployment ne gère pas directement les pods — il crée un ReplicaSet qui s'en charge. Ce niveau d'indirection permet les rolling updates.

### 3.3 Tester la résilience

```bash
# Supprimer un pod — le Deployment doit en recréer un immédiatement
POD_TO_DELETE=$(kubectl get pods -l app=nginx-app -o jsonpath='{.items[0].metadata.name}')
kubectl delete pod $POD_TO_DELETE

# Observer la recréation
kubectl get pods -l app=nginx-app -w
# Ctrl+C après avoir vu le nouveau pod passer en Running
```

**Output attendu :**

```
nginx-app-xxxxxxxxx-aaaaa     1/1     Terminating   0          8m
nginx-app-xxxxxxxxx-ccccc     0/1     Pending       0          2s
nginx-app-xxxxxxxxx-ccccc     1/1     Running       0          12s
```

> ✅ Le Deployment maintient toujours le nombre de réplicas demandé — si un pod disparaît, le ReplicaSet en recrée un automatiquement.

---

## Étape 4 — Test de rupture : ImagePullBackOff

Cette étape provoque volontairement une erreur pour apprendre à la diagnostiquer.

### 4.1 Déployer avec une image incorrecte

```bash
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-broken
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx-broken
  template:
    metadata:
      labels:
        app: nginx-broken
    spec:
      containers:
      - name: nginx
        image: ${ACR_LOGIN_SERVER}/nginx-app:v99.0   # Tag qui n'existe pas
        ports:
        - containerPort: 80
EOF
```

### 4.2 Observer et diagnostiquer

```bash
kubectl get pods -l app=nginx-broken --watch
# Ctrl+C après avoir vu ErrImagePull puis ImagePullBackOff
```

```bash
kubectl describe pod -l app=nginx-broken | grep -A10 "Events:"
```

**Output attendu :**

```
Events:
  Warning  Failed   20s  kubelet  Failed to pull image "...nginx-app:v99.0": not found
  Warning  BackOff  15s  kubelet  Back-off pulling image "...nginx-app:v99.0"
```

> ✅ **Diagnostic `ImagePullBackOff`**
>
> - `ErrImagePull` : première tentative échouée (image introuvable ou accès refusé)
> - `ImagePullBackOff` : Kubernetes attend exponentiellement avant de réessayer
>
> Causes fréquentes : tag incorrect, image non pushée, `--attach-acr` manquant, nom d'ACR incorrect.

```bash
# Nettoyer
kubectl delete deployment nginx-broken
```

---

## Récapitulatif des concepts

| Concept | Ce que vous avez fait |
|---|---|
| ACR + `az acr build` | Build d'image côté serveur, sans Docker local |
| `--attach-acr` | Pull depuis l'ACR via Managed Identity, sans credential |
| Deployment | Déclaration du nombre de réplicas et du template de pod |
| ReplicaSet | Maintient automatiquement le nombre de pods |
| Service LoadBalancer | IP publique Azure provisionnée automatiquement |
| `readinessProbe` | Trafic routé uniquement vers les pods prêts |
| `requests` / `limits` | Garantie et plafond de ressources CPU/mémoire |
| ImagePullBackOff | Diagnostic d'une image inaccessible |

---

## Questions de vérification

1. Quelle est la différence entre un `Deployment` et un `ReplicaSet` ? Pourquoi ce niveau d'indirection ?
2. Pourquoi le cluster peut-il puller depuis l'ACR sans `docker login` ni secret Kubernetes ?
3. Que se passe-t-il si vous supprimez un pod d'un Deployment manuellement ?
4. Quelle est la différence entre `requests` et `limits` sur les ressources d'un conteneur ?
5. Si votre Service reste en `<pending>` après 5 minutes, quelles causes investiguer ?
6. Quelle est la différence entre `ErrImagePull` et `ImagePullBackOff` ?

---

## Pour aller plus loin

- **Rolling update** : `kubectl set image deployment/nginx-app nginx=<ACR>/nginx-app:v2.0` et observer la mise à jour progressive
- **Rollback** : `kubectl rollout undo deployment/nginx-app`
- **Scaling** : `kubectl scale deployment nginx-app --replicas=4`

---

## Nettoyage

```bash
# Supprimer les ressources K8s uniquement (garder le cluster pour le lab suivant)
kubectl delete deployment nginx-app
kubectl delete service nginx-app-svc

# Ou utiliser le script de nettoyage
./lab1-cleanup.sh --k8s-only

# Ou supprimer le cluster AKS + ACR (le Resource Group est conservé)
./lab1-cleanup.sh --full
```
