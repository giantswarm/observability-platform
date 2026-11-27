# Verify signatures

Giant Swarm signs the dependency charts and the images of the platform with
[cosign](https://docs.sigstore.dev/cosign/) keyless signing. You can check a signature before
you install.

## What is signed

| Artifact | Location | Signed by |
| --- | --- | --- |
| The dependency charts listed in [`Chart.yaml`](../helm/observability-platform/Chart.yaml) | `oci://gsoci.azurecr.io/charts/giantswarm` | The Giant Swarm CircleCI job that publishes the chart |
| The images | `gsoci.azurecr.io/giantswarm` | The Giant Swarm CircleCI job that builds or mirrors the image |

Each signature carries a short-lived certificate for the OIDC identity of the CircleCI job. The
Rekor transparency log records the signature. The registry stores it next to the artifact.

## Verify a dependency chart

Take the chart name and version from [`Chart.yaml`](../helm/observability-platform/Chart.yaml).
This example verifies the Mimir chart:

```bash
cosign verify \
  --certificate-oidc-issuer-regexp '^https://oidc\.circleci\.com' \
  --certificate-identity-regexp '^https://circleci\.com/api/v2/projects/[a-f0-9-]+/pipeline-definitions/[a-f0-9-]+$' \
  gsoci.azurecr.io/charts/giantswarm/mimir:0.31.0
```

## Verify an image

Use the same flags with the image reference. This example verifies the Mimir image:

```bash
cosign verify \
  --certificate-oidc-issuer-regexp '^https://oidc\.circleci\.com' \
  --certificate-identity-regexp '^https://circleci\.com/api/v2/projects/[a-f0-9-]+/pipeline-definitions/[a-f0-9-]+$' \
  gsoci.azurecr.io/giantswarm/mimir:3.2.4
```

`cosign verify` exits with a non-zero code when the signature is missing, invalid or from
another identity.

## What the check proves

The identity regexp matches any Giant Swarm CircleCI pipeline. A passing check proves that a
Giant Swarm pipeline signed the artifact. It does not prove which source repository the
artifact comes from.

## Reference

The [architect orb signing documentation](https://github.com/giantswarm/architect-orb/blob/main/docs/cosign-signing.md#verifying-signatures-as-a-consumer)
describes the identity model and the verification of SBOM attestations.
