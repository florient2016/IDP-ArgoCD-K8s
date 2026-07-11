# Phase 3.5 — Gitea : forge Git interne (plan applicatif)

Architecture Git à deux étages :
- GitHub  = control plane : le repo platform (définition de l'IDP). Inchangé.
- Gitea   = plan applicatif : les projets itssolutions (code + repos *-config).

Boucle dev 100% locale : push Gitea -> webhook LAN -> Tekton -> Harbor
-> bump dans <app>-config (Gitea) -> Argo déploie. Zéro Internet, zéro NAT.

## 1. Secrets dans Vault (une fois)

```bash
V="kubectl -n vault-itssolutions exec -i vault-0 -- vault"

$V kv put secret/gitea admin-username='gitea-admin' admin-password='<FORT>'
# le PAT Gitea et le token SCM viendront après la création des comptes (§3)

# le PAT Gitea et le token SCM viendront après la création des comptes (§3)
```

## 2. Déployer Gitea

```bash
cp phase35/apps/gitea.yaml phase35/apps/gitea-config.yaml apps/
cp -r phase35/config/gitea config/
sed -i 's|<TON_ORG>|ton-org-github|g' apps/gitea-config.yaml
git add . && git commit -m "Phase 3.5: gitea (forge interne)" && git push
```

Waves : gitea-config (4) -> gitea (5). Premier démarrage ~2 min (migrations).
UI : https://git.apps.itssolutions.me — login avec le compte admin de Vault.



## 3. Organisation, comptes de service, tokens (une fois, via UI)

1. Créer l'organisation **itssolutions**.
2. Créer un compte de service **tekton-ci** (email fictif ok), l'ajouter
   à l'org avec droits d'écriture (team Owners ou team dédiée write).
3. PAT pour Tekton : connecté en tekton-ci -> Settings -> Applications ->
   Generate Token (scopes : repository read/write). Puis :

```bash
$V kv put secret/ci/git-credentials username='tekton-ci' password='<PAT_TEKTON>'
```

4. PAT pour Argo (lecture + listing org, pour l'ApplicationSet) : depuis
   l'admin ou un compte argocd dédié -> token scopes read:organization,
   read:repository. Deux secrets à créer côté cluster :

```bash
# a. Credentials de repo Argo (template pour tous les repos Gitea) :
kubectl -n argocd apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-gitea-creds
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repo-creds
stringData:
  type: git
  url: https://git.apps.itssolutions.me
  username: argocd
  password: <PAT_ARGO>
EOF

# b. Token pour le generator SCM de l'ApplicationSet :
kubectl -n argocd create secret generic gitea-scm-token \
  --from-literal=token='<PAT_ARGO>'
```

(Ces deux secrets sont du bootstrap Argo, même famille que le secret
GitHub existant — documentés ici, pas dans Git.)

## 4. Basculer la chaîne CI sur Gitea

Appliquer les diffs de diffs/ci-github-to-gitea.diff.md (4 changements),
commit, push. Puis déployer l'ApplicationSet :

```bash
cp phase35/apps/appset-itssolutions.yaml apps/
git add . && git commit -m "Phase 3.5: bascule CI sur gitea + ApplicationSet" && git push
```

Webhook côté Gitea (par repo applicatif, ou au niveau org -> hérité par
tous les repos — recommandé) :
  Org itssolutions -> Settings -> Webhooks -> Add webhook -> Gitea
  - URL : http://el-github-listener.ci.svc.cluster.local:8080
          (ou el-gitea-listener si renommé)
  - Secret : la valeur de secret/ci/github-webhook dans Vault
  - Events : Push

## 5. Test de bout en bout (la boucle complète)

```bash
# 1. Créer dans Gitea (org itssolutions) : demo-app (code) et demo-app-config
# 2. demo-app : un hello-world avec Dockerfile
# 3. demo-app-config : un chart Helm minimal dans deploy/ avec
#    image.repository=harbor.apps.itssolutions.me/apps/demo-app et image.tag
# 4. L'ApplicationSet découvre demo-app-config -> Application "app-demo-app"
kubectl -n argocd get application app-demo-app

# 5. Push un commit sur demo-app (main) :
#    webhook -> EventListener -> PipelineRun
kubectl -n ci get pipelinerun -w
# 6. Fin du run : commit "ci: bump ..." visible dans demo-app-config,
#    Argo synchronise, le pod tourne avec la nouvelle image :
kubectl -n demo-app get pods -w
```

Quand cette boucle tourne sans intervention : l'IDP est fonctionnellement
complet côté moteur. Il ne manque que le portail (Backstage, Phase 4).

## Exit criteria

- [ ] Gitea Healthy sur git.apps.itssolutions.me, org itssolutions créée
- [ ] clone/push par HTTPS avec PAT, sans warning TLS
- [ ] ApplicationSet : un repo *-config créé => Application Argo générée
- [ ] Boucle complète : push code -> image Harbor -> bump config -> déploiement
- [ ] Aucune règle NAT nécessaire (webhook 100% interne)

## Sizing

Gitea + son PostgreSQL : ~600 Mo RAM, 15 Gi de PVCs. Toujours faire un
kubectl top nodes après déploiement — Backstage (Phase 4) ajoutera ~1.5 Go.

## Note bootstrap / DR

Le control plane (platform) restant sur GitHub, la reconstruction du
cluster est inchangée. En revanche les repos GITEA (le code des apps)
vivent dans le cluster : leur sauvegarde = les PVCs gitea + postgresql.
Options : backups Longhorn vers NFS/S3 (recommandé, à configurer en
Phase 6 avec Velero), et/ou push-mirrors Gitea vers GitHub pour les
repos critiques (Settings du repo -> Mirror -> push mirror).


## Troubleshooting
kubectl annotate clustersecretstore vault force-sync=$(date +%s) --overwrite
# si pas d'effet en ~30 s, purge totale du cache ESO :
kubectl -n external-secrets rollout restart deploy external-secrets
kubectl get clustersecretstore vault -w

# 1. Charger le root token en variable de session (rien ne s'affiche à la saisie) :
read -s VROOT     # colle le root token depuis ton gestionnaire, puis Entrée

# 2. Recréer le wrapper :
vput() { kubectl -n vault-itssolutions exec -i vault-0 -- sh -c "VAULT_TOKEN='$VROOT' vault $*"; }

# 3. Et ta commande passe :
vput kv put secret/backstage \
  gitea-token='39d07aa1554d6XXXXXXXXXX' \
  backend-secret="$(openssl rand -hex 24)"

# vérification :
vput kv get secret/backstage