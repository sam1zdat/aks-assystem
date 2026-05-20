#!/usr/bin/env bash
#
# lab2-cleanup.sh
# -------------------------------------------------------------------
# Nettoie les ressources créées par le Lab 2 (Ingress).
#
# Usage :
#   ./lab2-cleanup.sh              # interactif
#   ./lab2-cleanup.sh --k8s-only   # namespace lab-ingress uniquement
#   ./lab2-cleanup.sh --full       # + ingress-nginx (libère le Load Balancer)
#   ./lab2-cleanup.sh --full --yes # sans confirmation
# -------------------------------------------------------------------

set -euo pipefail

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

MODE=""
AUTO_YES=0
NAMESPACE="lab-ingress"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --k8s-only)  MODE="k8s-only"; shift ;;
    --full)      MODE="full"; shift ;;
    --yes|-y)    AUTO_YES=1; shift ;;
    -h|--help)
      echo "Usage: $0 [--k8s-only | --full] [--yes] [-h]"
      echo "  --k8s-only   Supprime le namespace lab-ingress"
      echo "  --full       Supprime aussi ingress-nginx (libère le Load Balancer Azure)"
      exit 0 ;;
    *) err "Argument inconnu : $1"; exit 1 ;;
  esac
done

confirm() {
  if [[ "${AUTO_YES}" -eq 1 ]]; then return 0; fi
  read -r -p "$1 [o/N] " answer
  [[ "${answer}" =~ ^[OoYy]$ ]] || { warn "Abandon."; exit 0; }
}

echo
echo "${C_BOLD}======================================================================"
echo " Lab 2 — Nettoyage (Ingress)"
echo "======================================================================${C_RESET}"
echo

if [[ -z "${MODE}" ]]; then
  echo "  [1] ${C_YELLOW}Namespace uniquement${C_RESET} — supprime ${NAMESPACE}"
  echo "      Ingress Controller reste en place."
  echo
  echo "  [2] ${C_RED}Tout supprimer${C_RESET} — + ingress-nginx (libère le Load Balancer)"
  echo
  echo "  [q] Annuler"
  echo
  read -r -p "Choix [1/2/q] : " choice
  case "${choice}" in
    1) MODE="k8s-only" ;;
    2) MODE="full" ;;
    q|Q) exit 0 ;;
    *) err "Choix invalide."; exit 1 ;;
  esac
fi

confirm "Supprimer les ressources du Lab 2 ?"

if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  log "Suppression du namespace '${NAMESPACE}'..."
  cmd "kubectl delete namespace ${NAMESPACE} --wait=false"
  kubectl delete namespace "${NAMESPACE}" --wait=false
  ok "Namespace '${NAMESPACE}' supprimé"
else
  skip "Namespace '${NAMESPACE}' n'existe pas"
fi

if [[ "${MODE}" == "full" ]]; then
  if helm list -n ingress-nginx 2>/dev/null | grep -q ingress-nginx; then
    log "Désinstallation d'ingress-nginx via Helm..."
    cmd "helm uninstall ingress-nginx -n ingress-nginx"
    helm uninstall ingress-nginx -n ingress-nginx
    ok "ingress-nginx désinstallé"
  else
    skip "ingress-nginx n'est pas installé"
  fi
  if kubectl get namespace ingress-nginx >/dev/null 2>&1; then
    log "Suppression du namespace ingress-nginx..."
    cmd "kubectl delete namespace ingress-nginx --wait=false"
    kubectl delete namespace ingress-nginx --wait=false
    ok "Namespace ingress-nginx supprimé"
  fi
  echo
  echo "  ${C_DIM}Le Load Balancer Azure associé sera libéré.${C_RESET}"
fi

log "Suppression du fichier d'environnement..."
cmd "rm -f ${HOME}/.lab2-env"
rm -f "${HOME}/.lab2-env" 2>/dev/null && ok "Fichier ~/.lab2-env supprimé" || true

echo
ok "Nettoyage Lab 2 terminé."
echo
