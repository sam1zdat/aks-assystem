# LAB AVANCÉ — Stockage avancé : Azure Files, Blob CSI & expansion de volumes

> Partager du stockage entre pods avec Azure Files (ReadWriteMany), monter un conteneur Blob Storage comme filesystem, et étendre un volume sans interruption de service.
> Durée estimée : 1h20 · Niveau : Avancé

---

## Objectifs

**Partie A — Azure Files : stockage partagé ReadWriteMany (30 min)**
- Créer un PVC Azure Files accessible simultanément par plusieurs pods
- Démontrer l'écriture depuis un pod et la lecture depuis un autre en temps réel
- Comparer les accessModes `ReadWriteOnce` (Azure Disk) vs `ReadWriteMany` (Azure Files)
- Diagnostiquer l'échec d'un montage RWX sur un Azure Disk

**Partie B — Azure Blob Storage CSI (30 min)**
- Activer le driver CSI Blob sur le cluster AKS
- Créer une StorageClass custom pour le protocole NFS sur Blob
- Monter un conteneur Blob Storage comme système de fichiers dans un pod
- Vérifier les fichiers créés depuis Azure CLI
- Comprendre les limites du montage Blob (performances, compatibilité POSIX)

**Partie C — Expansion dynamique de PVC (20 min)**
- Créer un PVC avec une StorageClass qui autorise l'expansion
- Remplir partiellement le volume et observer l'espace disque
- Étendre le PVC à chaud (sans supprimer le pod)
- Diagnostiquer l'échec d'expansion sur une StorageClass non extensible

---

## Contexte

### Azure Disk vs Azure Files vs Blob Storage

```
                   Azure Disk           Azure Files          Blob Storage
                   ──────────           ───────────          ────────────
Type               Block storage        File share (SMB/NFS) Object storage
Access Mode        ReadWriteOnce        ReadWriteMany        ReadWriteMany
Performances       Élevées (SSD)        Moyennes             Variables
Cas d'usage        BDD, app mono-pod    Partage multi-pod    Données massives
Persistance        Oui                  Oui                  Oui
POSIX-compliant    Oui                  Partiel (NFS)        Non (fuse)
Coût               $$                   $$                   $
```

### Quand utiliser quel type ?

```
Un seul pod écrit ?
  │
  ├─ Oui → Azure Disk (ReadWriteOnce) — Lab 3
  │
  └─ Non, plusieurs pods ?
       │
       ├─ Fichiers partagés (config, logs, uploads) → Azure Files (ReadWriteMany)
       │
       └─ Données massives / archives / data lake → Blob Storage CSI
```

### Expansion de PVC

```
PVC : 2Gi (presque plein)
  │
  kubectl patch pvc → spec.resources.requests.storage: 5Gi
  │
  StorageClass (allowVolumeExpansion: true)
  │
  Azure Disk/Files redimensionne automatiquement
  │
  Pod voit 5Gi sans redémarrage
```

---

## Prérequis

> Ce lab suppose que le Lab 1 est terminé :
>
> - Cluster AKS opérationnel avec `kubectl get nodes` → Ready
> - Variables `$RG` et `$CLUSTER_NAME` définies
> - Azure CLI connecté (`az account show`)

```bash
# Vérifications
kubectl get nodes
kubectl get storageclass
az account show --query name -o tsv
```

**Output attendu :**

```
NAME                                STATUS   ROLES    AGE
aks-nodepool1-xxxxxxxx-vmss000000   Ready    <none>   1h

NAME                    PROVISIONER          RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION
azurefile               file.csi.azure.com   Delete          Immediate              true
azurefile-csi           file.csi.azure.com   Delete          Immediate              true
azurefile-csi-premium   file.csi.azure.com   Delete          Immediate              true
azurefile-premium       file.csi.azure.com   Delete          Immediate              true
default (default)       disk.csi.azure.com   Delete          WaitForFirstConsumer   true
managed                 disk.csi.azure.com   Delete          WaitForFirstConsumer   true
managed-csi             disk.csi.azure.com   Delete          WaitForFirstConsumer   true
managed-csi-premium     disk.csi.azure.com   Delete          WaitForFirstConsumer   true
managed-premium         disk.csi.azure.com   Delete          WaitForFirstConsumer   true
```

---

## Étape 0 — Variables d'environnement

```bash
# Charger les variables du Lab 1
source ~/.lab1-env
export NAMESPACE_FILES="lab-storage-files"
export NAMESPACE_BLOB="lab-storage-blob"
export NAMESPACE_EXPAND="lab-storage-expand"

# Vérifier
echo "RG       : $RG"
echo "Cluster  : $CLUSTER_NAME"
```

```bash
# Créer les namespaces
kubectl create namespace $NAMESPACE_FILES
kubectl create namespace $NAMESPACE_BLOB
kubectl create namespace $NAMESPACE_EXPAND
```

---

# PARTIE A — Azure Files : stockage partagé ReadWriteMany

## Étape 1 — Créer un PVC Azure Files

Contrairement à Azure Disk (`ReadWriteOnce`), Azure Files supporte `ReadWriteMany` : plusieurs pods sur des nœuds différents peuvent lire et écrire simultanément dans le même volume.

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-shared
  namespace: $NAMESPACE_FILES
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: azurefile-csi-premium
  resources:
    requests:
      storage: 5Gi
EOF
```

Vérifier :

```bash
kubectl get pvc -n $NAMESPACE_FILES
```

**Output attendu :**

```
NAME         STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS
pvc-shared   Bound    pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   5Gi        RWX            azurefile-csi-premium
```

> Contrairement à Azure Disk (`WaitForFirstConsumer`), Azure Files utilise `Immediate` — le volume est provisionné immédiatement, sans attendre qu'un pod le monte. Le statut est directement `Bound`.

---

## Étape 2 — Déployer deux pods qui partagent le volume

### 2.1 Pod écrivain

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: writer
  namespace: $NAMESPACE_FILES
spec:
  containers:
  - name: writer
    image: busybox:latest
    command: ["/bin/sh", "-c"]
    args:
    - |
      echo "Processus writer démarré" > /shared/status.txt
      i=1
      while true; do
        echo "[writer] message $i — $(date)" >> /shared/log.txt
        i=$((i+1))
        sleep 5
      done
    volumeMounts:
    - name: shared
      mountPath: /shared
    resources:
      requests: { cpu: "25m", memory: "32Mi" }
      limits:   { cpu: "50m", memory: "64Mi" }
  volumes:
  - name: shared
    persistentVolumeClaim:
      claimName: pvc-shared
EOF
```

### 2.2 Pod lecteur

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: reader
  namespace: $NAMESPACE_FILES
spec:
  containers:
  - name: reader
    image: busybox:latest
    command: ["/bin/sh", "-c"]
    args:
    - |
      echo "Attente des données..."
      while [ ! -f /shared/log.txt ]; do sleep 1; done
      echo "Fichier détecté, lecture en continu :"
      tail -f /shared/log.txt
    volumeMounts:
    - name: shared
      mountPath: /shared
    resources:
      requests: { cpu: "25m", memory: "32Mi" }
      limits:   { cpu: "50m", memory: "64Mi" }
  volumes:
  - name: shared
    persistentVolumeClaim:
      claimName: pvc-shared
EOF
```

### 2.3 Vérifier le partage en temps réel

```bash
# Attendre que les deux pods soient Running
kubectl get pods -n $NAMESPACE_FILES -w
# Ctrl+C quand les deux sont Running

# Lire les logs du reader — il voit les messages du writer en temps réel
kubectl logs reader -n $NAMESPACE_FILES --follow
```

**Output attendu :**

```
Fichier détecté, lecture en continu :
[writer] message 1 — Thu May 22 10:30:15 UTC 2025
[writer] message 2 — Thu May 22 10:30:20 UTC 2025
[writer] message 3 — Thu May 22 10:30:25 UTC 2025
...
```

> Le pod `reader` lit en temps réel ce que le pod `writer` écrit — les deux partagent le même Azure File Share via le PVC `ReadWriteMany`. Ceci est impossible avec un Azure Disk (`ReadWriteOnce`).

### 2.4 Vérifier depuis le writer

```bash
kubectl exec writer -n $NAMESPACE_FILES -- cat /shared/status.txt
# wc -l /shared/log.txt = "combien de lignes dans le fichier log.txt ?" 
kubectl exec writer -n $NAMESPACE_FILES -- wc -l /shared/log.txt
```

---

## Étape 3 — Test de rupture : ReadWriteMany sur Azure Disk

Que se passe-t-il si on tente un `ReadWriteMany` avec Azure Disk ?

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-disk-rwx
  namespace: $NAMESPACE_FILES
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: managed-csi-premium
  resources:
    requests:
      storage: 2Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: disk-rwx-test
  namespace: $NAMESPACE_FILES
spec:
  containers:
  - name: app
    image: nginx:alpine
    volumeMounts:
    - name: data
      mountPath: /data
    resources:
      requests: { cpu: "25m", memory: "32Mi" }
      limits:   { cpu: "50m", memory: "64Mi" }
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: pvc-disk-rwx
EOF
```

> La StorageClass `managed-csi-premium` utilise `WaitForFirstConsumer` — le PVC reste `Pending` tant qu'aucun pod ne le consomme. C'est le pod qui déclenche le provisionnement et donc l'erreur.

Attendre 30 secondes puis observer :

```bash
kubectl get pvc pvc-disk-rwx -n $NAMESPACE_FILES
kubectl describe pvc pvc-disk-rwx -n $NAMESPACE_FILES | tail -10
kubectl get pod disk-rwx-test -n $NAMESPACE_FILES
```

**Output attendu :**

```
NAME           STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS
pvc-disk-rwx   Pending                                      managed-csi-premium

Events:
  Normal   WaitForFirstConsumer  ...  waiting for first consumer to be created before binding
  Normal   Provisioning          ...  External provisioner is provisioning volume for claim ...
  Warning  ProvisioningFailed    ...  mountVolume is not supported for access mode: MULTI_NODE_MULTI_WRITER

NAME            READY   STATUS    RESTARTS   AGE
disk-rwx-test   0/1     Pending   0          40s
```

> **Diagnostic :** Azure Disk ne supporte que `ReadWriteOnce` (un seul nœud à la fois). Le pod et le PVC restent bloqués en `Pending`. Pour du stockage partagé multi-pod, utiliser Azure Files (`azurefile-csi` / `azurefile-csi-premium`).

```bash
# Nettoyer
kubectl delete pod disk-rwx-test -n $NAMESPACE_FILES
kubectl delete pvc pvc-disk-rwx -n $NAMESPACE_FILES
```

---

# PARTIE B — Azure Blob Storage CSI

## Étape 4 — Activer le driver CSI Blob

Le driver Blob CSI n'est pas installé par défaut sur AKS. Il faut l'activer via un addon.

```bash
# Activer le driver Blob CSI
az aks update \
  --name $CLUSTER_NAME \
  --resource-group $RG \
  --enable-blob-driver

# Vérifier que le driver est installé
kubectl get daemonset -n kube-system | grep blob
```

**Output attendu :**

```
csi-blob-node   1/1   1   1   1   1   <none>   2m
```

> L'activation prend 1-2 minutes. Un DaemonSet `csi-blob-node` est déployé sur chaque nœud.

---

## Étape 5 — Créer une StorageClass Blob NFS

```bash
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: blob-nfs
provisioner: blob.csi.azure.com
parameters:
  protocol: nfs
  skuName: Premium_LRS
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
mountOptions:
  - hard
  - nconnect=8
EOF
```

```bash
kubectl get storageclass blob-nfs
```

**Output attendu :**

```
NAME       PROVISIONER           RECLAIMPOLICY   VOLUMEBINDINGMODE
blob-nfs   blob.csi.azure.com    Delete          Immediate
```

> **Pourquoi NFS ?** Le protocole NFS est nécessaire pour monter un conteneur Blob comme filesystem POSIX dans un pod. L'alternative `fuse` est plus lente et moins compatible.
>
> **`nconnect=8`** ouvre 8 connexions TCP parallèles vers le serveur NFS — améliore le débit pour les accès concurrents.

---

## Étape 6 — Créer un PVC Blob et monter dans un pod

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-blob
  namespace: $NAMESPACE_BLOB
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: blob-nfs
  resources:
    requests:
      storage: 10Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: blob-writer
  namespace: $NAMESPACE_BLOB
spec:
  containers:
  - name: writer
    image: nginx:alpine
    volumeMounts:
    - name: blobdata
      mountPath: /data
    resources:
      requests: { cpu: "50m", memory: "64Mi" }
      limits:   { cpu: "100m", memory: "128Mi" }
  volumes:
  - name: blobdata
    persistentVolumeClaim:
      claimName: pvc-blob
EOF
```

```bash
# Attendre que le pod soit Running (le provisionnement NFS peut prendre 1-2 min)
kubectl get pod blob-writer -n $NAMESPACE_BLOB -w
```

> Le premier provisionnement d'un conteneur Blob NFS prend plus de temps qu'un Azure Disk (création du Storage Account + conteneur + endpoint NFS). Comptez 1-3 minutes.

---

## Étape 7 — Écrire des données et vérifier via Azure CLI

### 7.1 Écrire depuis le pod

```bash
kubectl exec blob-writer -n $NAMESPACE_BLOB -- sh -c '
  echo "Données stockées dans Azure Blob Storage" > /data/readme.txt
  echo "Fichier de configuration" > /data/config.yaml
  dd if=/dev/zero of=/data/largefile.bin bs=1M count=5 2>/dev/null
  ls -lh /data/
'
```

> Détail des commandes exécutées dans le pod :
>
> | Commande | Ce qu'elle fait |
> |---|---|
> | `echo "Données stockées..." > /data/readme.txt` | Crée un fichier texte dans le volume monté |
> | `echo "Fichier de configuration" > /data/config.yaml` | Crée un deuxième fichier |
> | `dd if=/dev/zero of=/data/largefile.bin bs=1M count=5 2>/dev/null` | Crée un fichier de 5 Mo rempli de zéros (simule un gros fichier) |
> | `ls -lh /data/` | Liste les fichiers avec leurs tailles lisibles (h = human-readable) |

**Output attendu :**

```
-rw-r--r--    1 root     root          42 May 22 10:45 readme.txt
-rw-r--r--    1 root     root          27 May 22 10:45 config.yaml
-rw-r--r--    1 root     root       5.0M May 22 10:45 largefile.bin
```

### 7.2 Vérifier depuis Azure CLI

```bash
# Trouver le Storage Account créé automatiquement via le PV
PV_NAME=$(kubectl get pvc pvc-blob -n $NAMESPACE_BLOB -o jsonpath='{.spec.volumeName}')
echo "PV : $PV_NAME"

# Extraire le nom du Storage Account depuis le PV
kubectl get pv $PV_NAME -o jsonpath='{.spec.csi.volumeAttributes.storageAccount}'
echo

# Ou lister tous les Storage Accounts du node RG
NODE_RG=$(az aks show -g $RG -n $CLUSTER_NAME --query nodeResourceGroup -o tsv)
az storage account list -g $NODE_RG --query "[].{Nom:name, Type:kind}" -o table
```

> Les fichiers créés dans `/data/` sont en réalité des blobs dans un conteneur Azure Blob Storage. Ils sont accessibles via Azure CLI, le portail Azure, ou tout SDK compatible Azure Storage.

---

## Étape 8 — Test de rupture : Blob sans protocole NFS

Que se passe-t-il si on crée une StorageClass Blob sans le protocole NFS ?

```bash
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: blob-fuse-test
provisioner: blob.csi.azure.com
parameters:
  skuName: Standard_LRS
reclaimPolicy: Delete
volumeBindingMode: Immediate
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-blob-fuse
  namespace: $NAMESPACE_BLOB
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: blob-fuse-test
  resources:
    requests:
      storage: 2Gi
EOF

# Attendre le provisionnement
kubectl get pvc pvc-blob-fuse -n $NAMESPACE_BLOB -w
```

> **Résultat :** le PVC est provisionné avec le protocole `fuse` par défaut. Ce protocole fonctionne mais avec des limitations :
> - Performances inférieures au NFS (~50% plus lent)
> - Compatibilité POSIX partielle (pas de `chmod`, `chown` limités)
> - Pas de support des liens symboliques
>
> **En production, toujours privilégier NFS** (`protocol: nfs`) pour des workloads qui manipulent des fichiers.

```bash
# Nettoyer
kubectl delete pvc pvc-blob-fuse -n $NAMESPACE_BLOB
kubectl delete storageclass blob-fuse-test
```

---

# PARTIE C — Expansion dynamique de PVC

> **Avant de commencer :** sur un nœud B2s (limite de 30 pods), le nœud peut être saturé après les parties A et B. Supprimer les pods des parties précédentes avant de continuer :
>
> ```bash
> kubectl delete pod writer reader -n $NAMESPACE_FILES
> kubectl delete pod blob-writer -n $NAMESPACE_BLOB
> ```

## Étape 9 — Créer un PVC extensible

Les StorageClasses AKS par défaut (`managed-csi`, `managed-csi-premium`) supportent déjà `allowVolumeExpansion: true`. On va l'utiliser directement.

```bash
# Vérifier que la StorageClass supporte l'expansion
kubectl get storageclass managed-csi-premium -o jsonpath='{.allowVolumeExpansion}'
echo
# Output attendu : true
```

```bash
# Créer un PVC de 2Gi
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-expandable
  namespace: $NAMESPACE_EXPAND
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: managed-csi-premium
  resources:
    requests:
      storage: 2Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: disk-user
  namespace: $NAMESPACE_EXPAND
spec:
  containers:
  - name: app
    image: nginx:alpine
    volumeMounts:
    - name: data
      mountPath: /data
    resources:
      requests: { cpu: "50m", memory: "64Mi" }
      limits:   { cpu: "100m", memory: "128Mi" }
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: pvc-expandable
EOF
```

```bash
# Attendre que le pod soit Running
kubectl get pod disk-user -n $NAMESPACE_EXPAND -w
```

---

## Étape 10 — Remplir le volume et observer l'espace

```bash
# Vérifier la taille actuelle
kubectl exec disk-user -n $NAMESPACE_EXPAND -- df -h /data
```

**Output attendu :**

```
Filesystem      Size  Used Avail Use% Mounted on
/dev/sdX        2.0G   24K  1.9G   1% /data
```

```bash
# Remplir avec 1.5 Gi de données
kubectl exec disk-user -n $NAMESPACE_EXPAND -- sh -c '
  dd if=/dev/zero of=/data/bigfile.bin bs=1M count=1500 2>/dev/null
  echo "Données critiques" > /data/important.txt
  df -h /data
'
```

```bash
# Vérifier la taille actuelle
kubectl exec disk-user -n $NAMESPACE_EXPAND -- df -h /data
```

**Output attendu :**

```
Filesystem      Size  Used Avail Use% Mounted on
/dev/sdX        2.0G  1.5G  395M  80% /data
```

> Le volume est à 80% — en production, c'est le moment d'étendre avant une panne.

---

## Étape 11 — Étendre le PVC à chaud

```bash
# Patcher le PVC pour demander 5Gi au lieu de 2Gi
kubectl patch pvc pvc-expandable -n $NAMESPACE_EXPAND \
  -p '{"spec": {"resources": {"requests": {"storage": "5Gi"}}}}'
```

```bash
# Observer l'état du PVC
kubectl get pvc pvc-expandable -n $NAMESPACE_EXPAND -w
```

**Output attendu (progression) :**

```
NAME             STATUS   VOLUME          CAPACITY   ACCESS MODES   STORAGECLASS         CONDITION
pvc-expandable   Bound    pvc-xxxxxxxx    2Gi        RWO            managed-csi-premium  FileSystemResizePending
pvc-expandable   Bound    pvc-xxxxxxxx    5Gi        RWO            managed-csi-premium
```

> La condition `FileSystemResizePending` signifie que le disque Azure a été redimensionné mais que le filesystem dans le pod n'a pas encore été étendu. Cela se fait automatiquement au prochain montage ou dynamiquement si le driver CSI le supporte.

```bash
# Vérifier l'espace dans le pod (sans redémarrage !)
kubectl exec disk-user -n $NAMESPACE_EXPAND -- df -h /data
```

**Output attendu :**

```
Filesystem      Size  Used Avail Use% Mounted on
/dev/sdX        4.9G  1.5G  3.3G  31% /data
```

> Le volume est passé de 2Gi à ~5Gi **sans interruption du pod**. Les données existantes sont intactes.

```bash
# Vérifier que les données sont toujours là
kubectl exec disk-user -n $NAMESPACE_EXPAND -- cat /data/important.txt
# Output attendu : Données critiques
```

---

## Étape 12 — Test de rupture : expansion sur StorageClass non extensible

Créer une StorageClass qui n'autorise pas l'expansion :

```bash
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: no-expand-test
provisioner: disk.csi.azure.com
parameters:
  skuName: Premium_LRS
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: false
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-no-expand
  namespace: $NAMESPACE_EXPAND
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: no-expand-test
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: no-expand-pod
  namespace: $NAMESPACE_EXPAND
spec:
  containers:
  - name: app
    image: nginx:alpine
    volumeMounts:
    - name: data
      mountPath: /data
    resources:
      requests: { cpu: "50m", memory: "64Mi" }
      limits:   { cpu: "100m", memory: "128Mi" }
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: pvc-no-expand
EOF

# Attendre que le pod soit Running
kubectl get pod no-expand-pod -n $NAMESPACE_EXPAND -w
```

Tenter l'expansion :

```bash
kubectl patch pvc pvc-no-expand -n $NAMESPACE_EXPAND \
  -p '{"spec": {"resources": {"requests": {"storage": "5Gi"}}}}'
```

**Output attendu :**

```
error: pvc-no-expand cannot be expanded: the StorageClass "no-expand-test"
does not allow volume expansion
```

> **Diagnostic :** si `allowVolumeExpansion` n'est pas `true` dans la StorageClass, Kubernetes refuse la modification du PVC. C'est un garde-fou pour les StorageClasses qui ne supportent pas le redimensionnement.
>
> **Bonne pratique :** en production, toujours utiliser `allowVolumeExpansion: true` sur les StorageClasses (c'est le cas par défaut sur AKS pour `managed-csi` et `managed-csi-premium`).

```bash
# Nettoyer
kubectl delete pod no-expand-pod -n $NAMESPACE_EXPAND
kubectl delete pvc pvc-no-expand -n $NAMESPACE_EXPAND
kubectl delete storageclass no-expand-test
```

---

## Nettoyage des ressources

```bash
# Supprimer tous les namespaces du lab
kubectl delete namespace $NAMESPACE_FILES
kubectl delete namespace $NAMESPACE_BLOB
kubectl delete namespace $NAMESPACE_EXPAND

# Supprimer les StorageClasses custom
kubectl delete storageclass blob-nfs 2>/dev/null || true

# Vérifier
kubectl get namespaces | grep lab-storage
```

> La suppression des namespaces supprime automatiquement les PVC, ce qui déclenche la suppression des disques Azure et des Azure File Shares associés (`ReclaimPolicy: Delete`). Les Storage Accounts créés par le driver Blob CSI sont également nettoyés.

---

## Récapitulatif des concepts vus

| Concept | Ce que vous avez fait |
|---|---|
| Azure Files (SMB/NFS) | Stockage partagé ReadWriteMany entre plusieurs pods |
| `azurefile-csi-premium` | StorageClass pré-configurée pour Azure Files Premium |
| ReadWriteMany vs ReadWriteOnce | RWX = multi-pod simultané, RWO = un seul nœud à la fois |
| Blob CSI driver | Addon AKS pour monter des conteneurs Blob Storage |
| Protocole NFS vs FUSE | NFS = performant/POSIX, FUSE = lent/limité |
| StorageClass custom | Définition de paramètres spécifiques (protocole, SKU, options de montage) |
| `allowVolumeExpansion` | Autorise le redimensionnement à chaud des PVC |
| `kubectl patch pvc` | Étendre un volume sans interruption de service |
| `FileSystemResizePending` | Le disque est agrandi, le filesystem sera étendu au prochain montage |

---

## Questions de vérification

1. Pourquoi Azure Disk ne supporte-t-il pas `ReadWriteMany` ? Quelle est la contrainte technique sous-jacente ?
2. Quelle est la différence entre Azure Files (SMB) et Azure Files (NFS) ? Dans quel scénario choisir l'un ou l'autre ?
3. Un pod écrit des fichiers dans un volume Blob CSI. Un autre pod ne voit pas les nouveaux fichiers. Quelles causes investiguer ?
4. L'expansion d'un PVC Azure Disk nécessite-t-elle un redémarrage du pod ? Et pour Azure Files ?
5. En production, un PVC de 100Gi est à 95% de capacité. Décrivez les étapes pour étendre à 200Gi sans interruption de service.
6. Pourquoi `nconnect=8` est-il recommandé dans les `mountOptions` pour Blob NFS ? Quel est l'impact sur les performances ?

---

## Pour aller plus loin

- **Azure Disk Shared** : depuis 2023, Azure Ultra Disk et Premium SSD v2 supportent `ReadWriteMany` pour les blocs (multi-attach). Utile pour les clusters de bases de données distribués (Oracle RAC, SAP HANA).
- **Azure NetApp Files** : service NFS/SMB haute performance pour les workloads entreprise (SAP, HPC). StorageClass `netappfiles-premium` avec des performances prévisibles (latence < 1ms).
- **VolumeSnapshots** : sauvegarder un PVC via `VolumeSnapshot` et le restaurer dans un nouveau PVC — indispensable pour les stratégies de backup Kubernetes (Velero).
- **CSI Volume Cloning** : créer un clone d'un PVC existant sans snapshot intermédiaire — utile pour dupliquer un environnement (staging → review).
- **Encryption at rest** : Azure Disk et Azure Files sont chiffrés par défaut (SSE). Pour du chiffrement avec clé client (CMK), configurer un DiskEncryptionSet dans la StorageClass.
