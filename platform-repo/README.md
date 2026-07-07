# Phase 2 — Vault + External Secrets (namespace: vault-itssolutions)

Objectif : plus aucun secret créé à la main. Vault stocke, ESO synchronise
vers les namespaces consommateurs. Premier cas d'usage : le token Cloudflare.

## 1. Ajouter les fichiers au repo platform

```bash
# Depuis la racine de ton repo platform :
cp platform-repo-additions/apps/*.yaml apps/
cp -r platform-repo-additions/config/external-secrets config/

# Remplacer <TON_ORG> dans apps/external-secrets-config.yaml
sed -i 's|<TON_ORG>|ton-org-github|g' apps/external-secrets-config.yaml

git add . && git commit -m "Phase 2: vault (ns vault-itssolutions) + external-secrets" && git push
```

Argo CD déploie : vault + external-secrets (wave 4), puis la config ESO
(wave 5). ATTENDU à ce stade :
- pod vault-0 : Running mais 0/1 Ready (Vault non initialisé = readiness KO)
- external-secrets-config : Degraded ("Vault is sealed") — le retry infini
  convergera après l'étape 2.

## 2. Initialiser et configurer Vault (une seule fois)

```bash
chmod +x vault-setup.sh
./vault-setup.sh
```

Le script : init (1 clé — lab), unseal, KV v2 sur secret/, auth Kubernetes,
policy lecture seule, rôle ESO, et stocke ton token Cloudflare.

⚠️ SAUVEGARDE l'unseal key et le root token HORS cluster (gestionnaire de
mots de passe). Perdus = coffre irrécupérable, il faudrait tout réinitialiser.

## 3. Vérifier la chaîne complète

```bash
kubectl get clustersecretstore vault
# STATUS: Valid, READY: True

kubectl -n cert-manager get externalsecret cloudflare-api-token
# STATUS: SecretSynced, READY: True

kubectl -n cert-manager get secret cloudflare-api-token -o yaml | grep ownerReferences -A3
# ownerReference -> ExternalSecret : ESO est maintenant propriétaire
```

Le secret manuel de la Phase 0/1 a été ADOPTÉ par ESO (creationPolicy:
Owner + même nom) : cert-manager n'a rien vu passer, aucun impact sur
les renouvellements de certificats.

NB : si l'ExternalSecret affichait une erreur de type "secret exists /
not owned", supprime simplement le secret manuel — ESO le recrée en
quelques secondes depuis Vault :
  kubectl -n cert-manager delete secret cloudflare-api-token

## 4. Test de bout en bout (le test qui prouve tout)

```bash
kubectl -n cert-manager delete secret cloudflare-api-token
# Attendre <1 min :
kubectl -n cert-manager get secret cloudflare-api-token
# Le secret est RECRÉÉ par ESO depuis Vault. Magique, mais surtout : GitOps.
```

## 5. Ajouter un nouveau secret (workflow désormais standard)

```bash
# a. Écrire dans Vault (UI https://vault.apps.itssolutions.me ou CLI) :
kubectl -n vault-itssolutions exec -i vault-0 -- \
  vault kv put secret/mon-app db-password='xxx'

# b. Committer un ExternalSecret dans config/external-secrets/ :
#    (copier externalsecret-cloudflare.yaml et adapter key/namespace)
# c. git push -> Argo -> ESO -> Secret. Zéro kubectl.
```

## 6. Limites assumées (lab)

- 1 seule unseal key (prod : 5 parts, seuil 3, ou auto-unseal via KMS)
- Unseal MANUEL après chaque redémarrage du pod vault-0 :
  `kubectl -n vault-itssolutions exec -i vault-0 -- vault operator unseal <KEY>`
- Le root token ne devrait servir qu'au setup — pour l'usage courant,
  créer des tokens/policies dédiés (on affinera en Phase 5 avec Kyverno).
- 1 réplica Raft : pas de HA (cohérent avec ton master unique).

## Exit criteria

- [ ] vault-0 Running 1/1 dans vault-itssolutions, UI accessible en HTTPS
- [ ] ClusterSecretStore vault : READY=True
- [ ] ExternalSecret cloudflare : SecretSynced
- [ ] Test destruction/recréation du secret : passe
- [ ] Unseal key + root token sauvegardés hors cluster
- [ ] Bootstrap cluster désormais : kubeadm -> root-app -> vault init/unseal
      -> restaurer les secrets Vault. Plus AUCUN kubectl create secret.

Next : Phase 3 — Harbor + Tekton (Harbor consommera ses credentials
depuis Vault via ESO, évidemment).
