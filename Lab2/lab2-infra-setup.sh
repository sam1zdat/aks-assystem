#!/usr/bin/env bash
#
# lab2-infra-setup.sh
# -------------------------------------------------------------------
# Prépare l'infrastructure pour le Lab 2 (Ingress & routage L7) :
#   - Charge les variables du Lab 1
#   - Crée le namespace dédié
#   - Installe l'Ingress Controller nginx via Helm
#   - Configure les probes TCP Azure
#   - Attend l'IP publique du contrôleur
#
# Usage :
#   ./lab2-infra-setup.sh              # paramètres par défaut
#   ./lab2-infra-setup.sh --dry-run    # affiche sans exécuter
#   ./lab2-infra-setup.sh --help
#
# Prérequis : Lab 1 terminé (cluster AKS opérationnel + ~/.lab1-env)
# -------------------------------------------------------------------

set -euo pipefail

# ---------- Couleurs (si terminal) --------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_BLUE=$'\033[34m'; C_DIM=$'\033[2m'
else
  C_RESET=""; C_BOLD=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""; C_DIM=""
fi

log()   { echo "${C_BLUE}==>${C_RESET} $*"; }
ok()    { echo "${C_GREEN}[OK]${C_RESET}    $*"; }
skip()  { echo "${C_DIM}[SKIP]  $*${C_RESET}"; }
warn()  { echo "${C_YELLOW}[WARN]${C_RESET}  $*"; }
err()   { echo "${C_RED}[ERR]${C_RESET}   $*" >&2; }
cmd()   { echo "    ${C_DIM}\$ $*${C_RESET}"; }

DRY_RUN=0
NAMESPACE="lab-ingress"

# ---------- Parsing arguments ------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)
      echo "Usage: $0 [--dry-run] [-h|--help]"
      echo "  Installe l'Ingress Controller nginx et prépare le namespace du Lab 2."
      echo "  Prérequis : Lab 1 terminé (cluster AKS + ~/.lab1-env)"
      exit 0 ;;
    *) err "Argument inconnu : $1"; exit 1 ;;
  esac
done

# ---------- Pré-checks --------------------------------------------
echo
echo "${C_BOLD}======================================================================"
echo " Lab 2 — Mise en place de l'infrastructure (Ingress)"
echo "======================================================================${C_RESET}"
echo

# Charger les variables du Lab 1
ENV_FILE_LAB1="${HOME}/.lab1-env"
if [[ -f "${ENV_FILE_LAB1}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE_LAB1}"
  ok "Variables Lab 1 chargées depuis ${ENV_FILE_LAB1}"
else
  err "Fichier ${ENV_FILE_LAB1} introuvable. Le Lab 1 doit être terminé d'abord."
  exit 1
fi

# Vérifier les outils
for tool in kubectl helm az; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    err "'${tool}' n'est pas installé."
    exit 1
  fi
done

# Vérifier la connexion au cluster
if ! kubectl get nodes >/dev/null 2>&1; then
  log "Récupération des credentials du cluster..."
  cmd "az aks get-credentials --name ${CLUSTER_NAME} --resource-group ${RG} --overwrite-existing"
  az aks get-credentials --name "${CLUSTER_NAME}" --resource-group "${RG}" --overwrite-existing
fi
ok "Cluster AKS accessible"

echo
echo "${C_BOLD}Configuration :${C_RESET}"
echo "  Cluster         : ${CLUSTER_NAME}"
echo "  Resource Group  : ${RG}"
echo "  Namespace       : ${NAMESPACE}"
if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "  Mode            : ${C_YELLOW}DRY-RUN${C_RESET}"
fi
echo

# ---------- Étape 1 : Namespace -----------------------------------
if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  skip "Namespace '${NAMESPACE}' existe déjà"
else
  log "Création du namespace '${NAMESPACE}'..."
  cmd "kubectl create namespace ${NAMESPACE}"
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    kubectl create namespace "${NAMESPACE}"
  fi
  ok "Namespace '${NAMESPACE}' créé"
fi

# ---------- Étape 2 : Ingress Controller nginx --------------------
if helm list -n ingress-nginx 2>/dev/null | grep -q ingress-nginx; then
  skip "ingress-nginx déjà installé"
else
  log "Ajout du dépôt Helm ingress-nginx..."
  cmd "helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx"
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
  fi

  log "Mise à jour des dépôts Helm..."
  cmd "helm repo update"
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    helm repo update >/dev/null
  fi

  log "Installation de l'Ingress Controller nginx via Helm (1 réplica)..."
  cmd "helm install ingress-nginx ingress-nginx/ingress-nginx \\
      --namespace ingress-nginx --create-namespace \\
      --set controller.replicaCount=1 \\
      --set controller.nodeSelector.kubernetes.io/os=linux \\
      --set controller.admissionWebhooks.patch.nodeSelector.kubernetes.io/os=linux"
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    helm install ingress-nginx ingress-nginx/ingress-nginx \
      --namespace ingress-nginx \
      --create-namespace \
      --set controller.replicaCount=1 \
      --set "controller.nodeSelector.kubernetes\.io/os=linux" \
      --set "controller.admissionWebhooks.patch.nodeSelector.kubernetes\.io/os=linux"
  fi
  ok "ingress-nginx installé"
fi

# ---------- Étape 3 : Probes TCP ---------------------------------
log "Configuration des probes Azure en TCP (port 80)..."
cmd "kubectl annotate svc ingress-nginx-controller -n ingress-nginx \\
    service.beta.kubernetes.io/port_80_health-probe_protocol=tcp --overwrite"
if [[ "${DRY_RUN}" -eq 0 ]]; then
  kubectl annotate svc ingress-nginx-controller -n ingress-nginx \
    service.beta.kubernetes.io/port_80_health-probe_protocol=tcp \
    --overwrite 2>/dev/null || true
fi

log "Configuration des probes Azure en TCP (port 443)..."
cmd "kubectl annotate svc ingress-nginx-controller -n ingress-nginx \\
    service.beta.kubernetes.io/port_443_health-probe_protocol=tcp --overwrite"
if [[ "${DRY_RUN}" -eq 0 ]]; then
  kubectl annotate svc ingress-nginx-controller -n ingress-nginx \
    service.beta.kubernetes.io/port_443_health-probe_protocol=tcp \
    --overwrite 2>/dev/null || true
fi
ok "Probes TCP configurés"

# ---------- Étape 4 : Attendre l'IP publique ----------------------
INGRESS_IP=""
log "Attente de l'IP publique du contrôleur Ingress..."
cmd "kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}'"
if [[ "${DRY_RUN}" -eq 0 ]]; then
  for i in $(seq 1 30); do
    INGRESS_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [[ -n "${INGRESS_IP}" ]]; then
      break
    fi
    sleep 5
  done
  if [[ -z "${INGRESS_IP}" ]]; then
    warn "L'IP publique n'est pas encore disponible. Vérifier manuellement :"
    warn "  kubectl get svc ingress-nginx-controller -n ingress-nginx"
  else
    ok "Ingress IP : ${INGRESS_IP}"
  fi
fi

# ---------- Récapitulatif ----------------------------------------
echo
echo "${C_BOLD}======================================================================"
echo " Infrastructure Lab 2 prête"
echo "======================================================================${C_RESET}"
echo
echo "  Ingress Controller : ingress-nginx (1 réplica)"
echo "  Ingress IP         : ${INGRESS_IP:-<en attente>}"
echo "  Namespace          : ${NAMESPACE}"
echo
echo "${C_BOLD}Prochaine étape :${C_RESET} reprendre le lab à l'${C_GREEN}Étape 1${C_RESET} (Déployer les applications)"
echo

# Exporter les variables
ENV_FILE="${HOME}/.lab2-env"
cat > "${ENV_FILE}" <<ENVEOF
# Variables Lab 2 — générées par lab2-infra-setup.sh le $(date '+%Y-%m-%d %H:%M')
export NAMESPACE_INGRESS="${NAMESPACE}"
export INGRESS_IP="${INGRESS_IP}"
ENVEOF

ok "Variables sauvegardées dans ${ENV_FILE}"
echo "  Pour les recharger : ${C_BOLD}source ~/.lab1-env && source ${ENV_FILE}${C_RESET}"
echo
