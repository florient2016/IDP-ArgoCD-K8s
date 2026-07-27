# SSO Plateforme — Dex + Gitea comme identité unique

Un compte Gitea = accès à Backstage, Argo CD, Grafana et Harbor.
Révocation centrale : désactiver le compte Gitea coupe tout.

## Ordre d'exécution

0. PRÉREQUIS : Gitea admin -> Applications -> OAuth2 App "dex"
   (redirect https://dex.apps.itssolutions.me/callback) -> ID+Secret,
   puis le vput kv put secret/dex ... (voir config/dex/externalsecret.yaml)
1. Dex : apps/dex.yaml + config/dex/ -> repo -> sync.
   Test : curl -s https://dex.apps.itssolutions.me/.well-known/openid-configuration | head -3
2. Argo CD : snippets/argocd-oidc.yaml (ESO Merge) + fusion du bloc
   oidc.config/rbac dans la config argocd-cm. Test : bouton "Gitea (SSO)".
3. Grafana : fusion du bloc dans kube-prometheus-stack values + l'ESO.
   Test : bouton "Sign in with Gitea (SSO)".
4. Harbor : snippets/harbor-oidc.md (UI admin). Test : LOGIN VIA OIDC.
5. Backstage : snippets/backstage-oidc.md (rebuild -> SHA -> bump).

## Filets de sécurité
- Chaque service GARDE son admin local en secours (Argo admin, Grafana
  admin, Harbor admin) — le SSO s'ajoute, il ne remplace pas le break-glass.
- Les robots Harbor (pipeline) ne sont pas affectés par le mode OIDC.
- Rollback par service : retirer le bloc de config = retour à l'état d'avant.

## Après
- oauth2-proxy devant Longhorn/Prometheus (services SANS auth native —
  Longhorn est aujourd'hui exposé sans authentification !) — lot suivant.
- Argo RBAC fin (groupes Gitea -> rôles) quand le besoin viendra.
