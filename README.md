# Phase 1 — Argo CD & GitOps (itssolutions.me)

Objectif : installer Argo CD, pousser le repo `platform`, et reprendre
les composants Phase 0 sous gestion GitOps. À la fin, le cluster entier
est reconstructible depuis Git.

## 1. Installer Argo CD

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm install argocd argo/argo-cd \
  -n argocd --create-namespace \
  -f argocd/values.yaml

kubectl -n argocd rollout status deploy/argocd-server

# Mot de passe admin initial
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

UI : https://argocd.apps.itssolutions.me (login `admin`).
Change le mot de passe (User Info → Update Password), puis supprime le secret initial :

```bash
kubectl -n argocd delete secret argocd-initial-admin-secret
```

## 2. Créer et pousser le repo platform

Crée un repo GitHub `platform` (privé de préférence), puis :

```bash
cd platform-repo
# Remplacer <TON_ORG> dans les 3 fichiers qui référencent le repo :
grep -rl "<TON_ORG>" . | xargs sed -i 's|<TON_ORG>|ton-org-github|g'

git init -b main
git add .
git commit -m "Phase 1: platform bootstrap (metallb, ingress-nginx, cert-manager, longhorn)"
git remote add origin git@github.com:ton-org-github/platform.git
git push -u origin main
```

Si le repo est privé, déclare-le dans Argo CD (UI → Settings →
Repositories → Connect repo, HTTPS + PAT GitHub en lecture seule).

## 3. Bootstrap : appliquer la root app

C'est la SEULE commande kubectl "applicative" restante — tout le reste
passera par Git désormais :

```bash
kubectl apply -f platform-repo/bootstrap/root-app.yaml
```

Argo CD découvre alors les 6 Applications dans apps/ et les synchronise
dans l'ordre des sync-waves : metallb (0) → metallb-config (1) →
ingress-nginx + cert-manager (2) → cert-manager-config + longhorn (3).

## 4. Adoption des composants existants — À LIRE

Les composants tournent déjà (installés par Helm CLI en Phase 0). Argo CD
va les ADOPTER, pas les réinstaller : il applique les mêmes manifests
par-dessus. Comportement attendu dans l'UI :

- Les apps apparaissent d'abord OutOfSync : normal, Argo ajoute ses
  labels de tracking. Le sync converge sans redéploiement destructif.
- AUCUNE coupure de service attendue : mêmes charts, mêmes values.
  Seule exception possible : un rolling restart des pods si une version
  de chart diffère légèrement de celle installée à la main.

Une fois toutes les apps Healthy/Synced, supprime les release records
Helm CLI (les ressources restent, seule la comptabilité Helm part) —
sinon `helm list` affichera des releases que Helm ne gère plus :

```bash
kubectl -n metallb-system   delete secret -l owner=helm,name=metallb
kubectl -n ingress-nginx    delete secret -l owner=helm,name=ingress-nginx
kubectl -n cert-manager     delete secret -l owner=helm,name=cert-manager
kubectl -n longhorn-system  delete secret -l owner=helm,name=longhorn
```

⚠️ Ne lance JAMAIS `helm uninstall` sur ces releases après adoption :
ça supprimerait les ressources que Argo gère.

## 5. Secrets — limite assumée de cette phase

Le secret `cloudflare-api-token` (namespace cert-manager) reste créé à
la main : on ne committe JAMAIS un secret en clair dans Git. Si tu
recrées le cluster, c'est la seule étape manuelle avant le bootstrap :

```bash
kubectl create ns cert-manager
kubectl -n cert-manager create secret generic cloudflare-api-token \
  --from-literal=api-token='<TOKEN>'
```

La Phase 2 (Vault + External Secrets) élimine cette étape.

## 6. Validation / exit criteria

- [ ] UI Argo CD accessible en HTTPS valide sur argocd.apps.itssolutions.me
- [ ] 7 applications (root + 6) Healthy et Synced
- [ ] Test self-heal : `kubectl -n ingress-nginx scale deploy
      ingress-nginx-controller --replicas=1` → Argo remet 2 en ~1 min
- [ ] Test GitOps : change une value dans un fichier apps/*.yaml, push,
      Argo applique en ~3 min sans aucun kubectl
- [ ] `helm list -A` ne montre plus que argocd

## 7. Reconstruction du cluster (le test ultime, un jour)

kubeadm + Calico → secret cloudflare → `kubectl apply -f bootstrap/root-app.yaml`
→ tout revient. C'est ça, la Phase 1 réussie.

Next : Phase 2 — Vault + External Secrets Operator (le secret Cloudflare
devient le premier cas d'usage), puis sealed du bootstrap complet.
