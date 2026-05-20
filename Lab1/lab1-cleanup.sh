#!/usr/bin/env bash
#
# lab1-cleanup.sh
# -------------------------------------------------------------------
# Nettoie toutes les ressources Azure créées par le Lab 1.
#
# Propose deux modes :
#   - Kubernetes uniquement : supprime les deployments/services du lab
#   - Complet : supprime le Resource Group entier (cluster + ACR + tout)
#
# Usage :
#   ./lab1-cleanup.sh                  # interactif (choix du mode)
#   ./lab1-cleanup.sh --k8s-only      # supprimer uniquement les ressources K8s
#   ./lab1-cleanup.sh --full           # supprimer le Resource Group complet
#   ./lab1-cleanup.sh --full --yes     # sans confirmation
#   ./lab1-cleanup.sh --help           # aide
#
# Le script tente de charger les variables depuis ~/.lab1-env
# (généré par lab1-infra-setup.sh). Sinon, utilise les valeurs par défaut.
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

# ---------- Valeurs par défaut ------------------------------------
PARTICIPANT_NUM=""
RG_PREFIX="rg-aks-formation"
RG=""
CLUSTER_NAME=""
MODE=""          # k8s-only | full
AUTO_YES=0

# Charger les variables du setup si disponibles
ENV_FILE="${HOME}/.lab1-env"
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

# Dériver RG et cluster si PARTICIPANT_NUM est chargé depuis l'env
if [[ -n "${PARTICIPANT_NUM}" ]]; then
  RG="${RG_PREFIX}-${PARTICIPANT_NUM}"
  CLUSTER_NAME="${CLUSTER_NAME:-aks-formation-${PARTICIPANT_NUM}}"
fi

# ---------- Parsing arguments ------------------------------------
show_help() {
  cat <<HELP_EOF
Usage: $0 [options]

Options:
  --k8s-only         Supprimer uniquement les ressources Kubernetes (deployments, services)
                     Le cluster AKS et l'ACR restent en place.
  --full             Supprimer le cluster AKS et l'ACR (le Resource Group est conservé)
  --participant N    Numéro du participant (auto-détecté depuis ~/.lab1-env si disponible)
  --cluster NAME     Nom du cluster AKS (défaut : aks-formation-N)
  --yes, -y          Pas de confirmation (pour automatisation)
  -h, --help         Affiche cette aide

Exemples:
  $0                         # mode interactif (charge ~/.lab1-env)
  $0 --k8s-only              # nettoyer K8s, garder l'infra
  $0 --full --yes            # supprimer cluster + ACR sans confirmation
  $0 --full --participant 3  # supprimer les ressources du participant 3
HELP_EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --k8s-only)    MODE="k8s-only"; shift ;;
    --full)        MODE="full"; shift ;;
    --participant) PARTICIPANT_NUM="$2"; shift 2 ;;
    --cluster)     CLUSTER_NAME="$2"; shift 2 ;;
    --yes|-y)      AUTO_YES=1; shift ;;
    -h|--help)     show_help ;;
    *)             err "Argument inconnu : $1"; exit 1 ;;
  esac
done

# Dériver RG et cluster si --participant passé en argument (priorité sur env)
if [[ -n "${PARTICIPANT_NUM}" ]]; then
  RG="${RG_PREFIX}-${PARTICIPANT_NUM}"
  CLUSTER_NAME="${CLUSTER_NAME:-aks-formation-${PARTICIPANT_NUM}}"
fi

# Vérifier qu'on a les infos nécessaires
if [[ -z "${RG}" ]] || [[ -z "${CLUSTER_NAME}" ]]; then
  err "Impossible de déterminer le Resource Group ou le cluster."
  err "Lancez le script avec --participant N ou assurez-vous que ~/.lab1-env existe."
  exit 1
fi

# ---------- Helpers -----------------------------------------------
confirm_action() {
  local message="$1"
  if [[ "${AUTO_YES}" -eq 1 ]]; then
    return 0
  fi
  read -r -p "${message} [o/N] " answer
  if [[ ! "${answer}" =~ ^[OoYy]$ ]]; then
    warn "Abandon."
    exit 0
  fi
}

# ---------- Pré-checks --------------------------------------------
echo
echo "${C_BOLD}======================================================================"
echo " Lab 1 — Nettoyage des ressources"
echo "======================================================================${C_RESET}"
echo

# Vérifier la connexion Azure
if ! az account show -o none 2>/dev/null; then
  err "Non connecté à Azure. Lancer 'az login' d'abord."
  exit 1
fi

SUBSCRIPTION_NAME=$(az account show --query "name" -o tsv)
ok "Connecté à Azure : ${SUBSCRIPTION_NAME}"
echo

# Vérifier que le RG existe
if ! az group show --name "${RG}" -o none 2>/dev/null; then
  warn "Le Resource Group '${RG}' n'existe pas. Rien à nettoyer."
  exit 0
fi

# ---------- Sélection du mode (interactif si non spécifié) --------
if [[ -z "${MODE}" ]]; then
  echo "  ${C_BOLD}Que souhaitez-vous supprimer ?${C_RESET}"
  echo
  echo "  [1] ${C_YELLOW}Kubernetes uniquement${C_RESET} — deployments et services du lab"
  echo "      Le cluster AKS, l'ACR et le Resource Group restent en place."
  echo "      Utile pour recommencer le lab depuis l'étape 3."
  echo
  echo "  [2] ${C_RED}Tout supprimer${C_RESET} — Cluster AKS + ACR"
  echo "      Supprime le cluster AKS et l'ACR. Le Resource Group est conservé."
  echo "      Arrête la facturation."
  echo
  echo "  [q] Annuler"
  echo
  read -r -p "Choix [1/2/q] : " choice
  case "${choice}" in
    1) MODE="k8s-only" ;;
    2) MODE="full" ;;
    q|Q) warn "Abandon."; exit 0 ;;
    *) err "Choix invalide."; exit 1 ;;
  esac
fi

# ---------- Mode 1 : K8s only ------------------------------------
if [[ "${MODE}" == "k8s-only" ]]; then
  echo
  log "Nettoyage des ressources Kubernetes dans '${CLUSTER_NAME}'..."

  # Vérifier que kubectl est configuré pour ce cluster
  CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "")
  if [[ -z "${CURRENT_CONTEXT}" ]]; then
    warn "kubectl n'a pas de contexte actif. Tentative de récupération des credentials..."
    cmd "az aks get-credentials --name ${CLUSTER_NAME} --resource-group ${RG} --overwrite-existing"
    az aks get-credentials --name "${CLUSTER_NAME}" --resource-group "${RG}" --overwrite-existing
  fi

  echo
  log "Ressources Kubernetes à supprimer :"

  # Lister ce qui sera supprimé
  DEPLOYMENTS=$(kubectl get deployments -n default -l app=nginx-app -o name 2>/dev/null || echo "")
  BROKEN_DEPLOY=$(kubectl get deployments -n default -l app=nginx-broken -o name 2>/dev/null || echo "")
  SERVICES=$(kubectl get svc -n default nginx-app-svc -o name 2>/dev/null || echo "")

  HAS_RESOURCES=0
  if [[ -n "${DEPLOYMENTS}" ]]; then
    echo "  - ${DEPLOYMENTS}"
    HAS_RESOURCES=1
  fi
  if [[ -n "${BROKEN_DEPLOY}" ]]; then
    echo "  - ${BROKEN_DEPLOY}"
    HAS_RESOURCES=1
  fi
  if [[ -n "${SERVICES}" ]]; then
    echo "  - ${SERVICES}"
    HAS_RESOURCES=1
  fi

  if [[ "${HAS_RESOURCES}" -eq 0 ]]; then
    skip "Aucune ressource Kubernetes du lab trouvée."
    echo
    exit 0
  fi

  echo
  confirm_action "Supprimer ces ressources ?"

  # Supprimer les deployments
  if [[ -n "${DEPLOYMENTS}" ]]; then
    log "Suppression du deployment nginx-app..."
    cmd "kubectl delete deployment -n default -l app=nginx-app"
    kubectl delete deployment -n default -l app=nginx-app 2>/dev/null && \
      ok "Deployment nginx-app supprimé" || skip "Deployment nginx-app non trouvé"
  fi
  if [[ -n "${BROKEN_DEPLOY}" ]]; then
    log "Suppression du deployment nginx-broken..."
    cmd "kubectl delete deployment -n default -l app=nginx-broken"
    kubectl delete deployment -n default -l app=nginx-broken 2>/dev/null && \
      ok "Deployment nginx-broken supprimé" || skip "Deployment nginx-broken non trouvé"
  fi

  # Supprimer le service
  if [[ -n "${SERVICES}" ]]; then
    log "Suppression du service nginx-app-svc..."
    cmd "kubectl delete svc -n default nginx-app-svc"
    kubectl delete svc -n default nginx-app-svc 2>/dev/null && \
      ok "Service nginx-app-svc supprimé" || skip "Service nginx-app-svc non trouvé"
  fi

  echo
  log "Vérification..."
  cmd "kubectl get all -n default"
  kubectl get all -n default 2>/dev/null || true

  echo
  ok "Nettoyage Kubernetes terminé. L'infrastructure Azure est intacte."
  echo "  Pour recommencer le lab : reprendre à l'${C_GREEN}Étape 3${C_RESET} du Lab 1."
  echo
fi

# ---------- Mode 2 : Full cleanup ---------------------------------
if [[ "${MODE}" == "full" ]]; then
  echo
  echo "  ${C_RED}${C_BOLD}SUPPRESSION DES RESSOURCES AKS${C_RESET}"
  echo
  echo "  Resource Group : ${C_BOLD}${RG}${C_RESET} (conservé — géré par le formateur)"
  echo
  echo "  Ceci va supprimer :"
  echo "    - Le cluster AKS '${CLUSTER_NAME}'"

  # Lister les ressources dans le RG
  log "Inventaire des ressources dans '${RG}'..."
  cmd "az resource list --resource-group ${RG} --query \"[].{Nom:name, Type:type}\" -o table"
  az resource list --resource-group "${RG}" --query "[].{Nom:name, Type:type}" -o table 2>/dev/null || true

  # Détecter l'ACR dans le RG
  ACR_IN_RG=$(az acr list --resource-group "${RG}" --query "[].name" -o tsv 2>/dev/null || echo "")
  if [[ -n "${ACR_IN_RG}" ]]; then
    echo "    - L'ACR '${ACR_IN_RG}'"
  fi

  echo
  confirm_action "${C_RED}Supprimer le cluster AKS et l'ACR dans '${RG}' ?${C_RESET}"

  # Supprimer le cluster AKS
  if az aks show --name "${CLUSTER_NAME}" --resource-group "${RG}" -o none 2>/dev/null; then
    log "Suppression du cluster AKS '${CLUSTER_NAME}'..."
    cmd "az aks delete --name ${CLUSTER_NAME} --resource-group ${RG} --yes --no-wait"
    az aks delete --name "${CLUSTER_NAME}" --resource-group "${RG}" --yes --no-wait
    ok "Suppression du cluster AKS lancée en arrière-plan"
  else
    skip "Cluster AKS '${CLUSTER_NAME}' non trouvé"
  fi

  # Supprimer l'ACR
  if [[ -n "${ACR_IN_RG}" ]]; then
    while IFS= read -r acr_name; do
      log "Suppression de l'ACR '${acr_name}'..."
      cmd "az acr delete --name ${acr_name} --resource-group ${RG} --yes"
      az acr delete --name "${acr_name}" --resource-group "${RG}" --yes 2>/dev/null && \
        ok "ACR '${acr_name}' supprimé" || warn "Échec de suppression de l'ACR '${acr_name}'"
    done <<< "${ACR_IN_RG}"
  fi

  echo
  echo "  ${C_YELLOW}Note :${C_RESET} Le Resource Group '${RG}' est conservé (géré par le formateur)."
  echo "  La suppression du cluster AKS peut prendre quelques minutes."
  echo

  # Nettoyer le kubeconfig
  log "Nettoyage du contexte kubectl..."
  cmd "kubectl config delete-context ${CLUSTER_NAME}"
  kubectl config delete-context "${CLUSTER_NAME}" 2>/dev/null && \
    ok "Contexte kubectl '${CLUSTER_NAME}' supprimé" || \
    skip "Contexte kubectl non trouvé"

  cmd "kubectl config delete-cluster ${CLUSTER_NAME}"
  kubectl config delete-cluster "${CLUSTER_NAME}" 2>/dev/null || true

  cmd "kubectl config delete-user clusterUser_${RG}_${CLUSTER_NAME}"
  kubectl config delete-user "clusterUser_${RG}_${CLUSTER_NAME}" 2>/dev/null || true

  # Nettoyer le fichier d'env
  if [[ -f "${ENV_FILE}" ]]; then
    log "Suppression du fichier d'environnement..."
    cmd "rm -f ${ENV_FILE}"
    rm -f "${ENV_FILE}"
    ok "Fichier ${ENV_FILE} supprimé"
  fi

  # Nettoyer le répertoire de travail
  if [[ -d "${HOME}/aks-lab-app" ]]; then
    read -r -p "Supprimer aussi le répertoire ~/aks-lab-app (Dockerfile, index.html) ? [o/N] " clean_dir
    if [[ "${clean_dir}" =~ ^[OoYy]$ ]]; then
      cmd "rm -rf ${HOME}/aks-lab-app"
      rm -rf "${HOME}/aks-lab-app"
      ok "Répertoire ~/aks-lab-app supprimé"
    else
      skip "Répertoire ~/aks-lab-app conservé"
    fi
  fi

  echo
  ok "Nettoyage terminé. Le Resource Group '${RG}' est intact."
  echo
fi
