# Scripts du Lab 1 — Infrastructure & Nettoyage

Deux scripts pour automatiser les parties passives du Lab 1 : la création de l'infrastructure Azure (5-10 min d'attente) et le nettoyage en fin de session. Les étapes pratiques (build, deploy, tests) restent **manuelles**.

---

## Fichiers

| Fichier | Rôle |
|---|---|
| `lab1-infra-setup.sh` | Crée le Resource Group, l'ACR et le cluster AKS (étapes 0-2 du lab) |
| `lab1-cleanup.sh` | Supprime les ressources K8s ou le Resource Group complet |

---

## Prérequis

- Azure CLI connecté (`lancer la commande : az login`)
- `kubectl` installé
- Rôle **Contributor** sur le Resource Group pré-assigné (`rg-aks-formation-N`)
- Quota suffisant dans `francecentral`

---

## lab1-infra-setup.sh

### Usage rapide

```bash
chmod +x lab1-infra-setup.sh
./lab1-infra-setup.sh --participant 3    # remplacer 3 par votre numéro
```

Le script vérifie que le Resource Group pré-assigné existe, puis crée l'ACR + le cluster AKS. À la fin, il sauvegarde toutes les variables dans `~/.lab1-env`.

Pour reprendre le lab après le script :

```bash
source ~/.lab1-env
# → reprendre à l'Étape 3 du Lab 1 (Builder l'image)
```

### Options

| Option | Description |
|---|---|
| `--participant N` | Numéro du participant (**requis**) → utilise `rg-aks-formation-N` |
| `--location REGION` | Région Azure (défaut : `francecentral`) |
| `--node-count N` | Nombre de nœuds (défaut : `1`) |
| `--node-size SIZE` | Taille des VMs (défaut : `Standard_B2s`) |
| `--acr NAME` | Nom ACR fixe au lieu de l'auto-généré |
| `--cluster NAME` | Nom du cluster (défaut : `aks-formation-N`) |
| `--dry-run` | Affiche les commandes sans rien exécuter |

Le script est **idempotent** : les ressources déjà existantes sont sautées (`[SKIP]`).

---

## lab1-cleanup.sh

### Usage rapide

```bash
chmod +x lab1-cleanup.sh
./lab1-cleanup.sh           # menu interactif
```

### Deux modes

| Mode | Commande | Ce qui est supprimé | Quand l'utiliser |
|---|---|---|---|
| K8s only | `--k8s-only` | Deployments + Services | Recommencer le lab depuis l'étape 3 |
| Full | `--full` | Cluster AKS + ACR (RG conservé) | Fin de session, arrêter la facturation |

```bash
./lab1-cleanup.sh --k8s-only          # nettoyer K8s, garder l'infra
./lab1-cleanup.sh --full              # tout supprimer
./lab1-cleanup.sh --full --yes        # tout supprimer sans confirmation
```

Le script charge automatiquement les variables depuis `~/.lab1-env`. En mode **full**, il nettoie aussi le kubeconfig et propose de supprimer `~/aks-lab-app`.

---

## Workflow type

```bash
# 1. Créer l'infra (début de session — remplacer N par votre numéro)
./lab1-infra-setup.sh --participant N

# 2. Charger les variables et suivre le lab (étapes 3 à 6)
source ~/.lab1-env

# 3. Si besoin de recommencer
./lab1-cleanup.sh --k8s-only
source ~/.lab1-env
# → reprendre à l'étape 3

# 4. Fin de session : nettoyage complet (cluster + ACR, RG conservé)
./lab1-cleanup.sh --full
```

---

## Troubleshooting

| Problème | Solution |
|---|---|
| `Non connecté à Azure` | `az login` (ou `az login --use-device-code` sur VM sans navigateur) |
| `kubectl n'est pas installé` | `az aks install-cli` ou relancer `install-linux-lab-tools.sh` |
| Erreur de quota (`QuotaExceeded`) | Portail Azure → Abonnements → Utilisation + quotas → demander 8 vCPUs DSv3 |
| Script interrompu pendant la création | Relancer tel quel — le script est idempotent |
| Variables perdues après déconnexion SSH | `source ~/.lab1-env` |
| Erreur `kubelogin` / `AADSTS700016` | `az aks install-cli` pour installer kubelogin |
