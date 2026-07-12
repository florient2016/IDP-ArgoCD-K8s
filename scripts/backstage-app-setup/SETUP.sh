# backstage-app — création du portail selon la méthode officielle
# (npx @backstage/create-app), à exécuter UNE FOIS sur ton poste.
# Prérequis poste : Node 20 LTS + yarn (corepack enable).

# ─── 1. Générer l'application ─────────────────────────────────────
npx @backstage/create-app@latest
#   App name: backstage-app
cd backstage-app

# ─── 2. Ajouter le module scaffolder Gitea (le but de la 4b) ──────
yarn --cwd packages/backend add @backstage/plugin-scaffolder-backend-module-gitea

# puis DÉCLARER le module dans packages/backend/src/index.ts,
# à côté des autres backend.add(...) du scaffolder :
#   backend.add(import('@backstage/plugin-scaffolder-backend-module-gitea'));

# ─── 3. app-config.production.yaml (racine du repo) ───────────────
# Remplacer INTÉGRALEMENT le fichier généré par :
cat > app-config.production.yaml <<'EOF'
app:
  baseUrl: https://backstage.apps.itssolutions.me

organization:
  name: itssolutions

backend:
  baseUrl: https://backstage.apps.itssolutions.me
  listen: { port: 7007 }
  auth:
    externalAccess:              # format moderne (backend.auth.keys est déprécié)
      - type: static
        options:
          token: ${BACKEND_SECRET}
          subject: internal-services
  database:
    client: pg
    connection:
      host: ${POSTGRES_HOST}
      port: ${POSTGRES_PORT}
      user: ${POSTGRES_USER}
      password: ${POSTGRES_PASSWORD}
  cors:
    origin: https://backstage.apps.itssolutions.me

integrations:
  gitea:
    - host: git.apps.itssolutions.me
      baseUrl: https://git.apps.itssolutions.me
      username: backstage
      password: ${GITEA_TOKEN}

auth:
  providers:
    guest:
      dangerouslyAllowOutsideDevelopment: true
      # LAB uniquement — la doc officielle exige un vrai provider en prod.
      # Durcissement prévu : OIDC (Keycloak/Dex) en phase 5/6.

catalog:
  rules:
    - allow: [Component, System, API, Resource, Location, Template, Group, User]
  locations:
    - type: url
      target: https://git.apps.itssolutions.me/itssolutions/idp-catalog/src/branch/main/catalog-info.yaml
    - type: url
      target: https://git.apps.itssolutions.me/itssolutions/idp-catalog/src/branch/main/templates/new-microservice/template.yaml
EOF

# ─── 4. Valider en local (optionnel mais recommandé, 5 min) ───────
yarn install --immutable
yarn tsc
yarn build:backend
# le build passe = l'app est saine avant même le pipeline

# ─── 5. Pousser dans Gitea ────────────────────────────────────────
git init -b main
git add .
git commit -m "feat: backstage-app initial (create-app + scaffolder gitea)"
git remote add origin https://tekton-ci:<PAT_TEKTON>@git.apps.itssolutions.me/itssolutions/backstage-app.git
git push -u origin main
# (créer d'abord le repo backstage-app dans l'org via l'UI admin,
#  SANS auto-init cette fois — on pousse un historique complet)

# NOTE : le Dockerfile généré par create-app (packages/backend/Dockerfile)
# est celui que le pipeline utilisera — ne pas le supprimer.
# NOTE anti-boucle : le webhook d'org va déclencher un build à ce push —
# c'est VOULU, c'est lui qui produira la première image (voir ci/).
