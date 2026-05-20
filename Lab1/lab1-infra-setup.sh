#!/usr/bin/env bash
#
# lab1-infra-setup.sh
# -------------------------------------------------------------------
# Provisionne l'infrastructure Azure pour le Lab 1 :
#   Resource Group + ACR + Cluster AKS
#
# Ce script automatise les étapes 0 à 2 du lab (attente passive).
# Les étapes 3 à 6 (build, deploy, tests) restent manuelles.
#
# Usage :
#   ./lab1-infra-setup.sh                          # paramètres par défaut
#   ./lab1-infra-setup.sh --location westeurope    # région différente
#   ./lab1-infra-setup.sh --node-count 3           # 3 nœuds
#   ./lab1-infra-setup.sh --dry-run                # affiche les commandes sans exécuter
#   ./lab1-infra-setup.sh --help                   # aide
#
# Idempotent : les ressources déjà existantes sont détectées et sautées.
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
LOCATION="francecentral"
CLUSTER_NAME=""
ACR_NAME=""
NODE_COUNT=1
NODE_SIZE="Standard_B2s"
DRY_RUN=0

# ---------- Parsing arguments ------------------------------------
show_help() {
  cat <<HELP_EOF
Usage: $0 --participant N [options]

Options:
  --participant N        Numéro du participant (REQUIS) → utilise rg-aks-formation-N
  --location REGION      Région Azure (défaut : francecentral)
  --cluster NAME         Nom du cluster AKS (défaut : aks-formation-N)
  --acr NAME             Nom de l'ACR (défaut : auto-généré)
  --node-count N         Nombre de nœuds (défaut : 1)
  --node-size SIZE       Taille des VMs (défaut : Standard_B2s)
  --dry-run              Affiche les commandes sans les exécuter
  -h, --help             Affiche cette aide

Exemples:
  $0 --participant 3
  $0 --participant 1 --location westeurope
  $0 --participant 5 --dry-run
HELP_EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --participant) PARTICIPANT_NUM="$2"; shift 2 ;;
    --location)    LOCATION="$2"; shift 2 ;;
    --cluster)     CLUSTER_NAME="$2"; shift 2 ;;
    --acr)         ACR_NAME="$2"; shift 2 ;;
    --node-count)  NODE_COUNT="$2"; shift 2 ;;
    --node-size)   NODE_SIZE="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)     show_help ;;
    *)             err "Argument inconnu : $1"; exit 1 ;;
  esac
done

# Vérifier que --participant est fourni
if [[ -z "${PARTICIPANT_NUM}" ]]; then
  err "Le paramètre --participant N est requis."
  echo "  Exemple : $0 --participant 3"
  echo "  Votre numéro de participant vous a été communiqué par le formateur."
  exit 1
fi

# Dériver RG et cluster name à partir du numéro de participant
RG="${RG_PREFIX}-${PARTICIPANT_NUM}"
if [[ -z "${CLUSTER_NAME}" ]]; then
  CLUSTER_NAME="aks-formation-${PARTICIPANT_NUM}"
fi

# ---------- Helpers -----------------------------------------------
run_cmd() {
  local description="$1"
  shift
  log "${description}"
  cmd "$@"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    return 0
  fi
  "$@"
}

check_tool() {
  local tool="$1"
  if ! command -v "${tool}" >/dev/null 2>&1; then
    err "'${tool}' n'est pas installé. Lancer le script d'installation (lab0) d'abord."
    exit 1
  fi
}

resource_exists() {
  local type="$1"
  case "${type}" in
    rg)
      az group show --name "${RG}" --query "name" -o tsv 2>/dev/null && return 0
      ;;
    acr)
      az acr show --name "${ACR_NAME}" --resource-group "${RG}" --query "name" -o tsv 2>/dev/null && return 0
      ;;
    aks)
      az aks show --name "${CLUSTER_NAME}" --resource-group "${RG}" --query "name" -o tsv 2>/dev/null && return 0
      ;;
  esac
  return 1
}

# ---------- Pré-checks --------------------------------------------
echo
echo "${C_BOLD}======================================================================"
echo " Lab 1 — Mise en place de l'infrastructure"
echo "======================================================================${C_RESET}"
echo

check_tool az
check_tool kubectl

# Vérifier la connexion Azure
SUBSCRIPTION_NAME=$(az account show --query "name" -o tsv 2>/dev/null) || {
  err "Non connecté à Azure. Lancer 'az login' d'abord."
  exit 1
}
SUBSCRIPTION_ID=$(az account show --query "id" -o tsv)
ok "Connecté à Azure : ${SUBSCRIPTION_NAME} (${SUBSCRIPTION_ID})"

# Générer le nom ACR si non fourni
if [[ -z "${ACR_NAME}" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    ACR_NAME="acrakslab$(openssl rand -hex 3)"
  else
    ACR_NAME="acrakslab$(printf '%06x' $RANDOM)"
  fi
fi

# Afficher la configuration
echo
echo "${C_BOLD}Configuration :${C_RESET}"
echo "  Participant     : ${C_BOLD}#${PARTICIPANT_NUM}${C_RESET}"
echo "  Resource Group  : ${RG} (pré-assigné)"
echo "  Région          : ${LOCATION}"
echo "  Cluster AKS     : ${CLUSTER_NAME}"
echo "  ACR             : ${ACR_NAME}"
echo "  Nœuds           : ${NODE_COUNT} x ${NODE_SIZE}"
echo "  Subscription    : ${SUBSCRIPTION_ID}"
if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "  Mode            : ${C_YELLOW}DRY-RUN (aucune ressource créée)${C_RESET}"
fi
echo

# Confirmation (sauf dry-run)
if [[ "${DRY_RUN}" -eq 0 ]]; then
  read -r -p "Continuer avec cette configuration ? [O/n] " confirm
  confirm="${confirm:-O}"
  if [[ ! "${confirm}" =~ ^[OoYy]$ ]]; then
    warn "Abandon."
    exit 0
  fi
fi

# ---------- Étape 1 : Vérification du Resource Group pré-assigné ---
echo
if resource_exists rg 2>/dev/null; then
  ok "Resource Group '${RG}' trouvé (pré-assigné par le formateur)"
else
  err "Le Resource Group '${RG}' n'existe pas."
  err "Vérifiez votre numéro de participant auprès du formateur."
  exit 1
fi

# ---------- Étape 2 : ACR ----------------------------------------
if resource_exists acr 2>/dev/null; then
  skip "ACR '${ACR_NAME}' existe déjà"
else
  run_cmd "Création de l'ACR '${ACR_NAME}' (SKU Basic)..." \
    az acr create \
      --name "${ACR_NAME}" \
      --resource-group "${RG}" \
      --location "${LOCATION}" \
      --sku Basic \
      --admin-enabled false \
      -o none
  ok "ACR créé"
fi

ACR_LOGIN_SERVER="${ACR_NAME}.azurecr.io"
if [[ "${DRY_RUN}" -eq 0 ]]; then
  ACR_LOGIN_SERVER=$(az acr show --name "${ACR_NAME}" --resource-group "${RG}" --query loginServer -o tsv 2>/dev/null || echo "${ACR_NAME}.azurecr.io")
fi
ok "ACR Login Server : ${ACR_LOGIN_SERVER}"

# ---------- Étape 3 : Cluster AKS --------------------------------
if resource_exists aks 2>/dev/null; then
  skip "Cluster AKS '${CLUSTER_NAME}' existe déjà"
else
  # Récupérer la version K8s par défaut
  K8S_VERSION=""
  log "Détection de la version Kubernetes par défaut dans '${LOCATION}'..."
  cmd "az aks get-versions --location ${LOCATION} --query \"values[?isDefault].version\" -o tsv"
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    K8S_VERSION=$(az aks get-versions \
      --location "${LOCATION}" \
      --query "values[?isDefault].version" -o tsv 2>/dev/null || echo "")
    if [[ -z "${K8S_VERSION}" ]]; then
      warn "Impossible de détecter la version par défaut. AKS utilisera sa version par défaut."
    else
      ok "Version Kubernetes : ${K8S_VERSION}"
    fi
  fi

  AKS_CREATE_ARGS=(
    az aks create
    --name "${CLUSTER_NAME}"
    --resource-group "${RG}"
    --location "${LOCATION}"
    --node-count "${NODE_COUNT}"
    --node-vm-size "${NODE_SIZE}"
    --network-plugin azure
    --enable-managed-identity
    --attach-acr "${ACR_NAME}"
    --enable-oidc-issuer
    --enable-workload-identity
    --generate-ssh-keys
    -o none
  )

  if [[ -n "${K8S_VERSION}" ]]; then
    AKS_CREATE_ARGS+=(--kubernetes-version "${K8S_VERSION}")
  fi

  log "Création du cluster AKS '${CLUSTER_NAME}' (${NODE_COUNT} x ${NODE_SIZE})..."
  cmd "${AKS_CREATE_ARGS[*]}"
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    "${AKS_CREATE_ARGS[@]}"
  fi
  ok "Cluster AKS créé"
fi

# ---------- Étape 4 : kubeconfig ---------------------------------
if [[ "${DRY_RUN}" -eq 0 ]]; then
  log "Configuration de kubectl..."
  cmd "az aks get-credentials --name ${CLUSTER_NAME} --resource-group ${RG} --overwrite-existing"
  az aks get-credentials \
    --name "${CLUSTER_NAME}" \
    --resource-group "${RG}" \
    --overwrite-existing
  ok "kubeconfig configuré"

  # Vérification
  echo
  log "Vérification du cluster..."
  cmd "kubectl get nodes"
  kubectl get nodes
else
  log "Configuration de kubectl..."
  cmd "az aks get-credentials --name ${CLUSTER_NAME} --resource-group ${RG} --overwrite-existing"
  echo
  log "Vérification du cluster..."
  cmd "kubectl get nodes"
fi

# ---------- Récapitulatif ----------------------------------------
echo
echo "${C_BOLD}======================================================================"
echo " Infrastructure prête"
echo "======================================================================${C_RESET}"
echo
echo "  Resource Group  : ${RG}"
echo "  ACR             : ${ACR_LOGIN_SERVER}"
echo "  Cluster AKS     : ${CLUSTER_NAME}"
echo "  Nœuds           : ${NODE_COUNT} x ${NODE_SIZE}"
echo
echo "${C_BOLD}Variables à copier dans votre terminal pour la suite du lab :${C_RESET}"
echo
echo "  export RG=\"${RG}\""
echo "  export LOCATION=\"${LOCATION}\""
echo "  export CLUSTER_NAME=\"${CLUSTER_NAME}\""
echo "  export ACR_NAME=\"${ACR_NAME}\""
echo "  export ACR_LOGIN_SERVER=\"${ACR_LOGIN_SERVER}\""
echo "  export SUBSCRIPTION_ID=\"${SUBSCRIPTION_ID}\""
echo
echo "${C_BOLD}Prochaine étape :${C_RESET} reprendre le lab à l'${C_GREEN}Étape 3${C_RESET} (Builder l'image)"
echo

# Exporter dans un fichier source pour faciliter la reprise
ENV_FILE="${HOME}/.lab1-env"
cat > "${ENV_FILE}" <<ENVEOF
# Variables Lab 1 — générées par lab1-infra-setup.sh le $(date '+%Y-%m-%d %H:%M')
export PARTICIPANT_NUM="${PARTICIPANT_NUM}"
export RG="${RG}"
export LOCATION="${LOCATION}"
export CLUSTER_NAME="${CLUSTER_NAME}"
export ACR_NAME="${ACR_NAME}"
export ACR_LOGIN_SERVER="${ACR_LOGIN_SERVER}"
export SUBSCRIPTION_ID="${SUBSCRIPTION_ID}"
export NODE_COUNT="${NODE_COUNT}"
export NODE_SIZE="${NODE_SIZE}"
export APP_NAME="nginx-app"
export NAMESPACE="default"
ENVEOF

ok "Variables sauvegardées dans ${ENV_FILE}"
echo "  Pour les recharger : ${C_BOLD}source ${ENV_FILE}${C_RESET}"
echo
