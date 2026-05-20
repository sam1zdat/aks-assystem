# Scripts du Lab 2 — Ingress

Deux scripts pour automatiser l'installation de l'Ingress Controller (attente passive) et le nettoyage. Les étapes pratiques (déploiement des apps, routage, tests) restent **manuelles**.

---

## Fichiers

| Fichier | Rôle |
|---|---|
| `lab2-infra-setup.sh` | Installe ingress-nginx via Helm, configure les probes TCP, attend l'IP |
| `lab2-cleanup.sh` | Supprime le namespace et optionnellement ingress-nginx |

---

## lab2-infra-setup.sh

```bash
chmod +x lab2-infra-setup.sh
./lab2-infra-setup.sh
```

Le script charge `~/.lab1-env`, crée le namespace `lab-ingress`, installe ingress-nginx (1 réplica), configure les probes TCP Azure et attend l'IP publique. Variables sauvegardées dans `~/.lab2-env`.

Pour reprendre le lab :

```bash
source ~/.lab1-env && source ~/.lab2-env
# → Étape 1 du lab participant
```

Idempotent — `--dry-run` disponible.

---

## lab2-cleanup.sh

| Mode | Commande | Ce qui est supprimé |
|---|---|---|
| Namespace seul | `--k8s-only` | `lab-ingress` |
| Tout | `--full` | + ingress-nginx (libère le Load Balancer) |

```bash
./lab2-cleanup.sh --k8s-only    # garder ingress-nginx
./lab2-cleanup.sh --full --yes  # tout supprimer sans confirmation
```

---

## Troubleshooting

| Problème | Solution |
|---|---|
| `~/.lab1-env introuvable` | Exécuter `lab1-infra-setup.sh` d'abord |
| IP Ingress en `<pending>` | Attendre 2 min, vérifier `kubectl get svc -n ingress-nginx` |
| Timeout sur curl | Probe Azure en HTTP → relancer le script ou refaire les annotations TCP |
