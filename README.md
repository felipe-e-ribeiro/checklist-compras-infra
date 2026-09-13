# checklist-compras-infra

Infra do app "compras" (checklist de compras compartilhado — código em
[checklist-compras](https://github.com/felipe-e-ribeiro/checklist-compras)),
via [`platform-chart`](https://github.com/felipe-e-ribeiro/personal-charts).

Migrado do chart bespoke (StatefulSet/Deployment escritos à mão) pro
`platform-chart` em 2026-09-13 — ver
`PERSONAL-INFRA-CONTEXT.md` no repo `Mycodes-Personal` pro histórico
completo da decisão.

## Estrutura

- `Chart.yaml` / `values.yaml`: consome o `platform-chart` como
  dependência — schema completo de cada seção em
  [`platform-chart/README.md`](https://github.com/felipe-e-ribeiro/personal-charts/blob/main/README.md)
  e `values.yaml` daquele repo.
- `resources.yaml`: documenta as chaves esperadas no secret do OCI Vault
  (`comprasweb-app-secrets`) — não consumido automaticamente ainda, é
  referência pra criar/atualizar o secret manualmente.
- `templates/external-secret.yaml`: `ExternalSecret` que materializa o
  secret do Vault como Secret do Kubernetes (`comprasweb-secrets`), via
  `ClusterSecretStore` (`argocd-bootstrap`).
- `kind-config.yaml` / `scripts/kind-setup.sh`: ambiente local via
  `kind`, sem depender do ClusterSecretStore (secret criado à mão pro
  teste local).

## Descoberta no cluster (ArgoCD)

Este app é descoberto automaticamente via
[`argocd-bootstrap/apps-registry/comprasweb.yaml`](https://github.com/felipe-e-ribeiro/argocd-bootstrap)
— sem `Application` escrita à mão. Namespace = `comprasweb` (não mais
`comprasweb-prod`).

## Secret no Vault

Criado/atualizado direto no Vault (não via `repository_dispatch`/Terraform):

```bash
oci vault secret create-base64 --profile DEV \
  --compartment-id <compartment_id> --vault-id <vault_id> --key-id <key_id> \
  --secret-name "comprasweb-app-secrets" \
  --secret-content-content "$(base64 -i secret.json)" \
  --secret-content-stage CURRENT --wait-for-state ACTIVE
```

`secret.json` com as chaves listadas em `resources.yaml`. Depois de
criar/atualizar, força o `ExternalSecret` a resincronizar na hora:

```bash
kubectl annotate externalsecret comprasweb-secrets -n comprasweb \
  force-sync="$(date +%s)" --overwrite
```

## Validar localmente (sem cluster)

```bash
helm dependency build .
helm template comprasweb . > /dev/null
```
