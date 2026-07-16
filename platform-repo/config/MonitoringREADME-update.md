# Phase 5 — Observabilité & Policies

Objectif : ne plus JAMAIS diagnostiquer un incident à l'aveugle. Chaque
alerte de cette phase correspond à un problème réellement vécu pendant
la construction de la plateforme.

## Composants

| Outil | Rôle | Accès |
|---|---|---|
| Prometheus | Métriques + règles d'alerte | (via Grafana) |
| Alertmanager | Routage des alertes | (UI interne) |
| Grafana | Dashboards + exploration logs | grafana.apps.itssolutions.me |
| Loki + Promtail | Agrégation des logs | (datasource Grafana) |
| Kyverno | Policies (garde-fous) | kubectl get cpol |
| tekton-pruner | Ménage auto des runs/PVC | CronJob 3h |

## Ordre de déploiement

```bash
cp phase5/apps/*.yaml            platform-repo/apps/
cp -r phase5/config/monitoring   platform-repo/config/
cp -r phase5/config/kyverno      platform-repo/config/
# les PrometheusRule/policies sont appliqués par des apps Argo dédiées,
# OU ajoutés au path d'une app existante — voir "Wiring" plus bas.
git add . && git commit -m "Phase 5: monitoring + policies" && git push
```

Waves : kube-prometheus-stack / loki / kyverno (8) → promtail (9).
Prévoir ~2 Go RAM supplémentaires (Prometheus ~1Gi, le reste réparti).
`kubectl top nodes` avant : les workers étaient à ~50%, surveiller.

## Wiring des règles et policies

Les fichiers `config/monitoring/idp-alerts.yaml` (PrometheusRule) et
`config/kyverno/policies.yaml` (ClusterPolicy) doivent être appliqués au
cluster. Deux options :
- **Simple** : une petite app Argo `monitoring-config` pointant
  `config/monitoring/` + `config/kyverno/` (wave 10, après que les CRDs
  Prometheus et Kyverno existent).
- Les CRD doivent exister AVANT (d'où la wave postérieure) — sinon
  erreurs "no matches for kind PrometheusRule/ClusterPolicy".

## Prérequis métriques (sinon certaines alertes restent muettes)

1. **Vault telemetry** → l'alerte VaultSealed a besoin des métriques Vault.
   Activer `telemetry { prometheus_retention_time = "24h" disable_hostname = true }`
   dans la config Vault + un ServiceMonitor (path /v1/sys/metrics,
   format=prometheus, avec un token lecture). Détail à câbler.
2. **Longhorn** expose déjà /metrics — un ServiceMonitor suffit
   (le chart Longhorn a `metrics.serviceMonitor.enabled=true`).
3. **cert-manager** : `prometheus.servicemonitor.enabled=true` dans ses values.

## Grafana — sécuriser le mot de passe

Le `adminPassword` en clair dans les values est une dette. Le remplacer
par un ExternalSecret (secret/grafana dans Vault) référencé via
`admin.existingSecret` dans les values du chart. À faire après le
premier login.

## Kyverno — Audit puis Enforce

TOUTES les policies sont en `validationFailureAction: Audit` : elles
RAPPORTENT sans bloquer. Vérifier les violations existantes :

```bash
kubectl get clusterpolicy
kubectl get polr -A          # PolicyReports : qui viole quoi
```

Corriger les violations (ex. les workloads sans limits, le tag initial
de hello-idp...), PUIS passer une policy en Enforce (éditer
validationFailureAction: Enforce) — une à la fois, jamais toutes d'un coup.
⚠️ En Enforce, `disallow-latest-tag` bloquerait un déploiement en latest :
s'assurer qu'aucun workload légitime n'en dépend avant de basculer.

## Dashboards Grafana recommandés (à importer par ID)

- 15757 (Kubernetes / Views / Global)
- 13639 (Loki logs)
- 16966 (Longhorn) — surveiller l'espace et la robustesse des volumes
- cert-manager (11001)

## Validation

- [ ] grafana.apps.itssolutions.me accessible, datasources Prometheus + Loki OK
- [ ] Targets Prometheus UP (Status → Targets)
- [ ] Les alertes idp-* visibles dans Prometheus (Alerts) — certaines
      PENDING/FIRING selon l'état réel (LonghornVolumeDegraded va
      probablement firer immédiatement — c'est le but !)
- [ ] Logs d'un pod visibles dans Grafana (Explore → Loki)
- [ ] kubectl get polr -A montre les PolicyReports
- [ ] Le CronJob tekton-pruner planifié

## Après la Phase 5

Le monitoring en place, revenir régler les dettes qu'il va RÉVÉLER :
volumes Longhorn degraded, workloads sans limits, tag initial. Puis
Phase 6 : Velero (backups — PVC Gitea/Vault en priorité), OIDC
(Keycloak/Dex), Crossplane.
