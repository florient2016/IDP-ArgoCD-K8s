# Phase 4 v2 — Backstage, la méthode officielle (correctif)

## Ce que la doc officielle corrige dans notre 4a

Constat (docs backstage.io/docs/deployment + le label de l'image ghcr) :

1. L'image ghcr.io/backstage/backstage est un ARTEFACT DE DÉMO —
   "ce que produirait create-app out of the box". Backstage est un
   FRAMEWORK : la méthode supportée est de générer SA propre app
   (npx @backstage/create-app) et de builder SA propre image.
   => nos 51 boots MigrationLocked sur des plugins de démo (signals,
   mcp-actions) étaient le symptôme d'un usage hors-doc.
2. Build recommandé = "host build" : yarn install -> tsc ->
   build:backend HORS de l'image, puis image runtime légère
   (Dockerfile généré par create-app).
   => traduit chez nous en task Tekton Node + kaniko runtime.
3. L'auth guest "n'est pas prévue pour les environnements
   conteneurisés" => on l'active explicitement
   (dangerouslyAllowOutsideDevelopment) en le documentant comme
   dette de lab ; OIDC prévu en durcissement.
4. backend.auth.keys est déprécié => app-config au format
   externalAccess (le warning vu dans nos logs).
5. La config vit dans le repo de l'app (app-config.production.yaml),
   versionnée — plus injectée par le chart.

## Exécution (ordre)

1. **backstage-app-setup/SETUP.sh** (sur ton poste) : create-app +
   module scaffolder Gitea + app-config.production.yaml + build local
   de validation + push vers Gitea (repo backstage-app, org itssolutions).

2. **ci/backstage-pipeline.yaml** -> copier dans platform-repo/config/ci/,
   commit, push, sync de l'app ci. Puis premier build :
   kubectl -n ci create -f <(grep -A22 "kind: PipelineRun" config/ci/backstage-pipeline.yaml)
   ou plus simple : kubectl create -f du bloc PipelineRun du fichier.
   Suivre : ~10-15 min (yarn). L'image arrive dans Harbor
   (apps/backstage-app:<sha>).
   ⚠️ Sizing : le task yarn demande 3-4 Gi RAM — vérifier kubectl top nodes
   avant, et lancer hors des heures où Harbor/Gitea sont sollicités.

3. **apps/backstage.yaml** (v2 fournie) : remplacer l'existant, mettre le
   tag = SHA du build, commit, push. L'app bascule sur TON image.
   Le pull secret harbor-pull doit exister dans le ns backstage :
   kubectl -n backstage create secret docker-registry harbor-pull \
     --docker-server=harbor.apps.itssolutions.me \
     --docker-username='robot$apps+ci' --docker-password='<TOKEN>'
   (à industrialiser en ExternalSecret comme les autres.)

4. **Reset propre du ns backstage** (on garde la DB) :
   - geler l'app, delete deploy backstage, purge sessions PG
     (la séquence connue), re-sync.
   - Re-patch strategy Recreate (ignoreDifferences v2 est au bon
     niveau + RespectIgnoreDifferences => il tiendra cette fois).

5. **Golden path** : dans idp-catalog, créer templates/new-microservice/
   avec template.yaml (fourni) + skeleton/ (Dockerfile hello-world +
   catalog-info.yaml templatisés) + skeleton-config/ (le chart deploy/
   de demo-app templatisé). Ajouter la location du template dans
   app-config (déjà fait dans le SETUP) ou via l'UI (Register).

## Validation finale de la Phase 4

- [ ] Pod backstage 1/1 avec l'image harbor.../apps/backstage-app:<sha>
- [ ] initialization complete SANS signals ni mcp-actions dans la liste
- [ ] Catalog : idp-platform + composants + demo-app
- [ ] Create -> "Nouveau microservice" -> nom "hello-idp" ->
      2 repos créés, pipeline déclenché, app-hello-idp dans Argo,
      https://hello-idp.apps.itssolutions.me répond.
      => LE golden path : idée -> prod en ~5 minutes, zéro kubectl.

## Dettes documentées (pour le durcissement)

- auth guest (lab) -> OIDC/Keycloak
- tag image à bump manuellement -> étendre gitops-bump au backstage.yaml
- harbor-pull manuel -> ExternalSecret
- TechDocs en mode local -> S3/MinIO
