#!/usr/bin/env bash
#
# vault-setup.sh — Configuration post-déploiement de Vault
# Namespace : vault-itssolutions
#
# À lancer UNE FOIS après que Argo CD a déployé Vault (pod vault-0 Running 0/1).
# Étapes : init -> unseal -> KV v2 -> auth Kubernetes -> policy -> rôle ESO
#          -> stockage du token Cloudflare.
#
set -euo pipefail

NS="vault-itssolutions"
POD="vault-0"

vexec() { kubectl -n "$NS" exec -i "$POD" -- sh -c "$*"; }

echo "==> 1. Initialisation (1 clé/1 seuil : LAB uniquement — en prod : 5/3)"
if vexec "vault status -format=json" 2>/dev/null | grep -q '"initialized": true'; then
  echo "    Vault déjà initialisé, on saute."
  echo "    (exporte VAULT_UNSEAL_KEY et VAULT_ROOT_TOKEN avant de relancer)"
  : "${VAULT_UNSEAL_KEY:?déjà initialisé : exporte VAULT_UNSEAL_KEY}"
  : "${VAULT_ROOT_TOKEN:?déjà initialisé : exporte VAULT_ROOT_TOKEN}"
else
  INIT_OUT=$(vexec "vault operator init -key-shares=1 -key-threshold=1 -format=json")
  VAULT_UNSEAL_KEY=$(echo "$INIT_OUT" | grep -o '"unseal_keys_b64": \[[^]]*' | grep -o '"[A-Za-z0-9+/=]\{20,\}"' | head -1 | tr -d '"')
  VAULT_ROOT_TOKEN=$(echo "$INIT_OUT" | grep -o '"root_token": "[^"]*' | cut -d'"' -f4)
  echo ""
  echo "    ┌──────────────────────────────────────────────────────────┐"
  echo "    │  SAUVEGARDE CES DEUX VALEURS HORS DU CLUSTER (KeePass…)  │"
  echo "    │  Perdues = Vault et tous ses secrets irrécupérables.     │"
  echo "    └──────────────────────────────────────────────────────────┘"
  echo "    UNSEAL KEY : $VAULT_UNSEAL_KEY"
  echo "    ROOT TOKEN : $VAULT_ROOT_TOKEN"
  echo ""
  read -rp "    Tape 'ok' quand c'est sauvegardé : " ack
  [ "$ack" = "ok" ] || { echo "Abandon."; exit 1; }
fi

echo "==> 2. Unseal"
vexec "vault operator unseal $VAULT_UNSEAL_KEY" >/dev/null
echo "    Vault unsealed."

echo "==> 3. Login root (session de config uniquement)"
vexec "vault login -no-print $VAULT_ROOT_TOKEN"

echo "==> 4. Moteur KV v2 sur secret/"
vexec "vault secrets enable -path=secret kv-v2" 2>/dev/null || echo "    secret/ déjà activé."

echo "==> 5. Auth Kubernetes"
vexec "vault auth enable kubernetes" 2>/dev/null || echo "    auth kubernetes déjà activée."
vexec 'vault write auth/kubernetes/config kubernetes_host="https://\$KUBERNETES_SERVICE_HOST:\$KUBERNETES_SERVICE_PORT"'

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
echo "    kubectl get clustersecretstore vault                       # READY=True attendu"
echo "    kubectl -n cert-manager get externalsecret                 # SecretSynced attendu"
echo "    kubectl -n cert-manager get secret cloudflare-api-token    # désormais géré par ESO"
echo ""
echo "⚠️  RAPPEL OPÉRATIONNEL : à chaque redémarrage du pod vault-0,"
echo "    Vault redémarre SCELLÉ. Pour le déverrouiller :"
echo "    kubectl -n $NS exec -i $POD -- vault operator unseal <UNSEAL_KEY>"
