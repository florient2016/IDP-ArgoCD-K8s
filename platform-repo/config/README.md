# Phase 4 — Backstage : le portail développeur

Architecture : Backstage (chart officiel) + PostgreSQL via CloudNativePG
+ secrets Vault/ESO + intégration Gitea. En 4a le portail lit (catalogue) ;
en 4b il écrit (scaffolder = golden path).

## 1. Secrets dans Vault (une fois)

```bash
vput kv put secret/backstage \
  gitea-token='<PAT_BACKSTAGE>' \
  backend-secret="$(openssl rand -hex 24)"
```

## 2. Compte de service Gitea "backstage" (une fois, via UI admin)

1. Site Administration -> Créer un compte : backstage / backstage@itssolutions.me
2. L'ajouter à l'org itssolutions, team dédiée (ou Owners si tu veux
   qu'il crée des repos dès la 4b — sinon team write)
3. Connecté en backstage -> Settings -> Applications -> Generate Token :
   - 4a (catalogue seul) : organization Read + repository Read
   - 4b (scaffolder) : organization RW + repository RW  <- recommandé
     directement pour ne pas re-générer dans 2 jours
4. => c'est le <PAT_BACKSTAGE> de l'étape 1.

## 3. Le repo catalogue

Créer (en admin, owner=itssolutions) le repo **idp-catalog**, y committer
les 3 fichiers depuis catalog/idp-catalog-content.yaml (découper aux
marqueurs "─── Fichier :") : catalog-info.yaml, platform.yaml, demo-app.yaml.
Remplacer <TON_ORG> dans platform.yaml.

## 4. Déployer

```bash
cp phase4/apps/*.yaml platform-repo/apps/
cp -r phase4/config/backstage platform-repo/config/
sed -i 's|<TON_ORG>|ton-org-github|g' platform-repo/apps/backstage-config.yaml
git add . && git commit -m "Phase 4: backstage + cnpg" && git push
```

Waves : cnpg (5) -> backstage-config (6 : cluster PG + secrets) ->
backstage (7). Le cluster PG met ~1 min ; Backstage ~2 min au premier boot.

Validation :
- [ ] pod backstage-db-1 Running (CNPG), secret backstage-db-app généré
- [ ] pod backstage 1/1, UI sur https://backstage.apps.itssolutions.me
- [ ] Catalogue : le System idp-platform + les composants + demo-app visibles
- [ ] Les liens (Argo, Harbor, Gitea, prod demo-app) fonctionnent

## 5. Phase 4b — le golden path (le vrai enjeu)

L'image upstream ne contient PAS le module scaffolder Gitea. Le plan —
et c'est un exercice IDP parfait puisque TA propre plateforme va
construire son propre portail :

1. Repo Gitea itssolutions/backstage-app : un `npx @backstage/create-app`,
   ajouter @backstage/plugin-scaffolder-backend-module-gitea (action
   publish:gitea), committer le Dockerfile généré.
2. Le pipeline Tekton (déjà en place ! le webhook d'org couvre ce repo)
   builde et pousse harbor.apps.../apps/backstage-app:<sha>.
   NB : build lourd (yarn) — prévoir 10-15 min et augmenter les limits
   du task kaniko (2Gi) pour ce repo.
3. apps/backstage.yaml : image -> Harbor + imagePullSecrets, et ajout
   du Software Template "new-microservice" au catalogue.
4. Le template scaffolder crée <app> + <app>-config dans Gitea ->
   le webhook d'org déclenche le premier build -> l'ApplicationSet
   découvre <app>-config -> déployé. Le clic "Create" -> prod en 5 min.

Je fournirai le squelette backstage-app + le template au moment voulu.

## Sizing

+ ~1.2 Go RAM (backstage ~700Mi, PG ~300Mi, opérateur ~150Mi), 5 Gi PVC.
kubectl top nodes après déploiement ; worker1 était à 48%, ça passe.

## Pièges connus

- postgresql.enabled: false OBLIGATOIRE dans les values : le sous-chart
  DB du chart Backstage est Bitnami => images retirées de Docker Hub
  (la leçon Gitea). CNPG nous en affranchit définitivement.
- Le service DB CNPG s'appelle <cluster>-rw (backstage-db-rw) : c'est
  l'endpoint d'écriture, toujours celui-là pour une app.
- image tag "latest" en 4a : assumé pour démarrer, la 4b le remplace
  par une image Harbor taggée SHA — ne pas rester en latest.
- Si l'UI affiche "failed to fetch" sur le catalogue : vérifier le
  GITEA_TOKEN (scopes) et que idp-catalog est accessible à ce compte.
