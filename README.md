# Vulnerability report of the published images

Scanned **2026-11-27** (UTC) by [`scan-releases.yaml`](https://github.com/alfsch/supertuxkart-server/blob/main/.github/workflows/scan-releases.yaml), every day,
for every release image that is still in the registry. Trivy counts the **fixable HIGH and CRITICAL** vulnerabilities of the **Debian
packages**. The libraries compiled into the STK binary (bullet, enet, mcpp, ...) and the game data are not covered.

## Which image do I run?

Find your release in the table. If you use `:1.5` or `:latest`, that is the **newest** release at the time you pulled. To see the
digest of the image you run:

```sh
docker image inspect ghcr.io/alfsch/supertuxkart-server:1.5 --format '{{index .RepoDigests 0}}'
```

## Releases, newest first

| Release | Platform | Critical | High | Image digest | Details |
|---|---|---|---|---|---|
| 1.5.10 | linux/amd64 | 0 | 1 | `sha256:5c5cbe5c08cb…` | [details](details/amd64-5c5cbe5c08cb.md) |
| 1.5.10 | linux/arm64 | 0 | 1 | `sha256:5e1fd0f71567…` | [details](details/arm64-5e1fd0f71567.md) |
| 1.5.9 | linux/amd64 | 0 | 1 | `sha256:cdf387420c68…` | [details](details/amd64-cdf387420c68.md) |
| 1.5.9 | linux/arm64 | 0 | 1 | `sha256:8d7faaaf02f7…` | [details](details/arm64-8d7faaaf02f7.md) |
| 1.5.8 | linux/amd64 | 0 | 1 | `sha256:3ca0700b03f8…` | [details](details/amd64-3ca0700b03f8.md) |
| 1.5.8 | linux/arm64 | 0 | 1 | `sha256:9c8df6cb60fa…` | [details](details/arm64-9c8df6cb60fa.md) |
| 1.5.7 | linux/amd64 | 0 | 1 | `sha256:fab9c701dd00…` | [details](details/amd64-fab9c701dd00.md) |
| 1.5.7 | linux/arm64 | 0 | 1 | `sha256:9a5d98360c43…` | [details](details/arm64-9a5d98360c43.md) |
| 1.5.6 | linux/amd64 | 0 | 57 | `sha256:67a991f66c3c…` | [details](details/amd64-67a991f66c3c.md) |
| 1.5.6 | linux/arm64 | 0 | 57 | `sha256:f04b291ba551…` | [details](details/arm64-f04b291ba551.md) |
| 1.5.5 | linux/amd64 | 0 | 57 | `sha256:c85c0885c297…` | [details](details/amd64-c85c0885c297.md) |
| 1.5.5 | linux/arm64 | 0 | 57 | `sha256:a102367a3d34…` | [details](details/arm64-a102367a3d34.md) |
| 1.5.0 to 1.5.4 | linux/amd64 | 0 | 57 | `sha256:34d4221d9be7…` | [details](details/amd64-34d4221d9be7.md) |
| 1.5.0 to 1.5.4 | linux/arm64 | 0 | 57 | `sha256:cce3e658ca8b…` | [details](details/arm64-cce3e658ca8b.md) |
