# v1.1.0 finalization

Framework views use the stable major-version tag `codebeltnet/docfx:2` with `--pull always`. Codebelt's upstream promotion makes compatible builder updates available without an action release. Set `framework-views: true` to use the upstream generator and its bundled NGINX Dockerfile with `.docfx/docfx.json`. Consumers can supply their own Dockerfile. The legacy path retains its independently configurable DocFX CLI.

The action exposes the documentation archive, detached SHA-256 checksum and OCI index digest after verification. An export or verification failure removes unverified files. The documentation archive retains both target platforms and the consumer's release version and Git revision.

## Builder validation

The PR checks verify that the stable tag publishes `linux/amd64` and `linux/arm64` OCI image manifests. The integration tests exercise framework generation, routing, bundled and custom packaging, and verification of the resulting documentation archive. Follow the [validation commands](README.md#validation) for Cuemon acceptance using the bundled Dockerfile's hardened default and caller-managed `dhi.io` credentials.

## Upstream release history

The initial framework-view validation used `codebeltnet/docfx:2.81.0-v1.1.0` with DocFX CLI 2.81.0 and Codebelt engine 1.1.0. Upstream merged revision `aa0150169358bc9a5763cf644778f442e174e49e` and published OCI index `sha256:40446dfb0045d02ac281190c20eb8a1c9c06797dbe59a710c7078bcd7179346a` for `linux/amd64` and `linux/arm64`. [Upstream PR #4](https://github.com/codebeltnet/docfx/pull/4) · [Verified release metadata](https://github.com/codebeltnet/docfx/releases/download/v1.1.0/docfx-release.json)
