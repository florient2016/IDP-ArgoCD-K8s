# backstage-app — création du portail (méthode officielle create-app)

⚠️ GUIDE À SUIVRE LIGNE À LIGNE sur ton poste — PAS un script à exécuter
d'un bloc (create-app est INTERACTIF ; l'exécution en nohup a déjà fait
des dégâts une fois).

Prérequis poste : Node 20 ou 22 via **nvm** (jamais le nodejs dnf —
crash libnode/c-ares sur RHEL) + `corepack enable`.

## 1. Générer l'application (hors de tout repo git existant !)

```bash
mkdir -p ~/work && cd ~/work
npx @backstage/create-app@latest
#   App name: backstage-app   (question interactive)
cd backstage-app
```

## 2. Ajouter le module scaffolder Gitea

```bash
yarn --cwd packages/backend add @backstage/plugin-scaffolder-backend-module-gitea
```

Puis ÉDITER `packages/backend/src/index.ts` — près des lignes scaffolder
existantes, AJOUTER :

```typescript
backend.add(import('@backstage/plugin-scaffolder-backend-module-gitea'));
```

## 3. ⚠️ RETIRER les plugins à problème (CRITIQUE)

create-app inclut PAR DÉFAUT des plugins qui perdent systématiquement la
course de migrations knex au boot (MigrationLocked — 51 restarts sur
l'image démo). Dans `packages/backend/src/index.ts` :

```bash
grep -n "signals\|mcp-actions\|kubernetes" packages/backend/src/index.ts
```

SUPPRIMER les lignes :
```typescript
backend.add(import('@backstage/plugin-signals-backend'));
backend.add(import('@backstage/plugin-mcp-actions-backend'));
backend.add(import('@backstage/plugin-kubernetes-backend'));   // non configuré, inutile
```

Vérification : le grep ne doit plus rien retourner (hors module gitea).

## 4. app-config.production.yaml (remplacer INTÉGRALEMENT)

```yaml
app:
  baseUrl: https://backstage.apps.itssolutions.me

organization:
  name: itssolutions

backend:
  baseUrl: https://backstage.apps.itssolutions.me
  listen: { port: 7007 }
  auth:
    externalAccess:              # backend.auth.keys est déprécié
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
      # LAB uniquement — vrai provider (OIDC) prévu au durcissement.
      # Au login : popup "fallback to legacy guest token" → cliquer OK (connu).

catalog:
  rules:
    - allow: [Component, System, API, Resource, Location, Template, Group, User]
  locations:
    - type: url
      target: https://git.apps.itssolutions.me/itssolutions/idp-catalog/src/branch/main/catalog-info.yaml
    - type: url
      target: https://git.apps.itssolutions.me/itssolutions/idp-catalog/src/branch/main/templates/new-microservice/template.yaml
```

## 5. Dockerfile en node 22

Le Dockerfile généré (packages/backend/Dockerfile) démarre en node:20 —
le bug undici/node-gyp (`markAsUncloneable is not a function`) casse la
compilation des modules natifs. Basculer :

```bash
sed -i 's/node:20/node:22/' packages/backend/Dockerfile
```

## 6. Validation locale (LE jalon)

```bash
yarn install --immutable   # les échecs better-sqlite3/isolated-vm/cpu-features
                           # sont ACCEPTABLES en local (gcc RHEL) — ils
                           # compileront dans le conteneur Debian du pipeline
yarn tsc && yarn build:backend
echo "exit: $?"            # 0 = OK, on push
```

## 7. Push vers Gitea

Créer d'abord le repo `backstage-app` dans l'UI Gitea (owner=itssolutions,
SANS auto-init — push-to-create est désactivé pour les orgs).

```bash
git init -b main
git add .
git status | grep -E "\.yarn|yarnrc"   # .yarnrc.yml et .yarn/ DOIVENT être stagés (Yarn Berry)
git commit -m "feat: backstage-app initial (create-app + scaffolder gitea, sans signals/mcp-actions)"
git remote add origin https://tekton-ci:<PAT_TEKTON>@git.apps.itssolutions.me/itssolutions/backstage-app.git
git push -u origin main
```

NB : le webhook d'org déclenchera un run du pipeline générique qui
échouera (pas de Dockerfile racine) — bruit connu, le filtre CEL doit
exclure backstage-app (voir triggers.yaml).
