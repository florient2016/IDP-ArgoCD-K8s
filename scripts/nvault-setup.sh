#!/usr/bin/env bash
#
# vault-setup.sh (v2 — durci) — Configuration post-déploiement de Vault
# Namespace : vault-itssolutions
#
# À lancer après que vault-0 est STABLE en Running 0/1 (non initialisé).
# Étapes : init -> unseal -> KV v2 -> auth Kubernetes -> policy -> rôle ESO
#          -> stockage du token Cloudflare.
#
# Durcissements v2 :
#   - trap ERR : toute erreur affiche la ligne et la commande fautives
#   - la sortie d'init est écrite dans un FICHIER avant tout parsing
#     (les clés ne peuvent plus être perdues par un échec de parsing)
#   - parsing JSON via python3 (plus de grep fragile)
#   - variables VSETUP_* : aucune collision possible avec l'env VAULT_*
#   - VAULT_CLIENT_TIMEOUT=600 dans le pod (stockage lent toléré)
#   - pré-vol : vérifie que le pod est Running et que vault status répond
#
# Cas "Vault déjà initialisé" : exporter avant de lancer :
#   export VSETUP_UNSEAL_KEY='...'
#   export VSETUP_ROOT_TOKEN='...'
#
set -euo pipefail
trap 'echo "ERREUR ligne $LINENO — commande: $BASH_COMMAND" >&2' ERR

NS="vault-itssolutions"
POD="vault-0"

vexec() { kubectl -n "$NS" exec -i "$POD" -- sh -c "export VAULT_CLIENT_TIMEOUT=600; $*"; }

command -v python3 >/dev/null || { echo "python3 requis pour le parsing JSON"; exit 2; }

echo "==> 0. Pré-vol"
PHASE=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Absent")
if [ "$PHASE" != "Running" ]; then
  echo "    Le pod $POD est en état '$PHASE' (attendu: Running). On ne lance PAS l'init"
  echo "    sur un pod instable — stabilise d'abord, puis relance."
  exit 2
fi
if ! STATUS_JSON=$(vexec "vault status -format=json" 2>/dev/null); then
  # vault status retourne un code != 0 quand sealed/non-init : on récupère quand même la sortie
  STATUS_JSON=$(vexec "vault status -format=json || true")
fi
[ -n "$STATUS_JSON" ] || { echo "    Impossible d'obtenir 'vault status' — Vault n'écoute pas ?"; exit 2; }
INITIALIZED=$(echo "$STATUS_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin)['initialized'])")
echo "    Pod Running, vault status OK (initialized=$INITIALIZED)."

echo "==> 1. Initialisation (1 clé/1 seuil : LAB uniquement — en prod : 5/3)"
if [ "$INITIALIZED" = "True" ] || [ "$INITIALIZED" = "true" ]; then
  echo "    Vault déjà initialisé — bascule en mode reprise."
  : "${VSETUP_UNSEAL_KEY:?déjà initialisé : exporte VSETUP_UNSEAL_KEY (depuis ton gestionnaire de mots de passe)}"
  : "${VSETUP_ROOT_TOKEN:?déjà initialisé : exporte VSETUP_ROOT_TOKEN}"
else
  INIT_FILE="$HOME/vault-init-$(date +%Y%m%d-%H%M%S).json"
  vexec "vault operator init -key-shares=1 -key-threshold=1 -format=json" > "$INIT_FILE"
  chmod 600 "$INIT_FILE"
  echo "    Sortie d'init sauvegardée dans : $INIT_FILE"

  VSETUP_UNSEAL_KEY=$(python3 -c "import json;print(json.load(open('$INIT_FILE'))['unseal_keys_b64'][0])")
  VSETUP_ROOT_TOKEN=$(python3 -c "import json;print(json.load(open('$INIT_FILE'))['root_token'])")

  echo ""
  echo "    ┌──────────────────────────────────────────────────────────┐"
  echo "    │  SAUVEGARDE CES DEUX VALEURS HORS DU CLUSTER (KeePass…)  │"
  echo "    │  Perdues = Vault et tous ses secrets irrécupérables.     │"
  echo "    └──────────────────────────────────────────────────────────┘"
  echo "    UNSEAL KEY : $VSETUP_UNSEAL_KEY"
  echo "    ROOT TOKEN : $VSETUP_ROOT_TOKEN"
  echo ""
  read -rp "    Tape 'ok' quand c'est sauvegardé : " ack
  if [ "$ack" != "ok" ]; then
    echo "Abandon. Les clés restent disponibles dans $INIT_FILE — sauvegarde-les puis supprime le fichier."
    exit 1
  fi
fi

echo "==> 2. Unseal"
vexec "vault operator unseal $VSETUP_UNSEAL_KEY" >/dev/null
echo "    Vault unsealed."

echo "==> 3. Login root (session de config uniquement)"
vexec "vault login -no-print $VSETUP_ROOT_TOKEN"

echo "==> 4. Moteur KV v2 sur secret/"
vexec "vault secrets enable -path=secret kv-v2" 2>/dev/null || echo "    secret/ déjà activé."

echo "==> 5. Auth Kubernetes"
vexec "vault auth enable kubernetes" 2>/dev/null || echo "    auth kubernetes déjà activée."
vexec 'vault write auth/kubernetes/config kubernetes_host="https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT"'

echo "==> 6. Policy lecture seule pour ESO"
vexec 'vault policy write external-secrets - <<EOF
path "secret/data/*"     { capabilities = ["read"] }
path "secret/metadata/*" { capabilities = ["read", "list"] }
EOF'

echo "==> 7. Rôle Kubernetes lié au ServiceAccount ESO"
vexec "vault write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=external-secrets \
  ttl=1h"

echo "==> 8. Premier secret : le token Cloudflare"
if [ -z "${CLOUDFLARE_TOKEN:-}" ]; then
  read -rsp "    Colle ton token API Cloudflare : " CLOUDFLARE_TOKEN; echo
fi
vexec "vault kv put secret/cloudflare api-token='$CLOUDFLARE_TOKEN'"

echo ""
echo "==> Terminé. Vérifications :"
echo "    kubectl get clustersecretstore vault                       # READY=True attendu (1-2 min)"
echo "    kubectl -n cert-manager get externalsecret                 # SecretSynced attendu"
echo "    kubectl -n cert-manager get secret cloudflare-api-token    # désormais géré par ESO"
echo ""
echo "    Une fois les clés dans ton gestionnaire de mots de passe,"
echo "    SUPPRIME le fichier d'init : rm -f \$HOME/vault-init-*.json"
echo ""
echo "⚠️  RAPPEL OPÉRATIONNEL : à chaque redémarrage du pod vault-0,"
echo "    Vault redémarre SCELLÉ. Pour le déverrouiller :"
echo "    kubectl -n $NS exec -i $POD -- vault operator unseal <UNSEAL_KEY>"
