# v1.1.0 finalization

Framework views use the upstream DocFX builder with CLI 2.81.0 and Codebelt engine 1.1.0. Set `framework-views: true` to use the upstream generator and its bundled NGINX Dockerfile with `.docfx/docfx.json`. Consumers can supply their own Dockerfile. The legacy path retains its independently configurable DocFX CLI.

The action exposes the documentation archive, detached SHA-256 checksum and OCI index digest after verification. An export or verification failure removes unverified files. The documentation archive retains both target platforms and the consumer's release version and Git revision.

## Release dependency

The approved builder is `codebeltnet/docfx:2.81.0-v1.1.0`. The upstream PR was merged as `aa0150169358bc9a5763cf644778f442e174e49e`. Its Docker Hub tag must be promoted before the action's framework-view path can be used from the registry. The upstream release workflow produces, verifies and promotes the builder OCI artifact. This repository uses that image to produce a separate consumer documentation OCI artifact. [Upstream PR #4](https://github.com/codebeltnet/docfx/pull/4)

## Updating the builder dependency

1. Choose the exact DocFX CLI and Codebelt engine release. Confirm the upstream release and verified promotion, then inspect the engine-qualified Docker Hub tag with `docker buildx imagetools inspect`. Confirm `linux/amd64` and `linux/arm64` and compare the registry index digest with the upstream release evidence. Check the image's CLI, engine and source revision labels.
2. Change the single builder declaration in `scripts/build-docfx-oci.ps1` and update the contract expectations and release documentation. Use the engine-qualified tag.
3. Run the PR checks and Cuemon acceptance. Use the bundled hardened Dockerfile with caller-managed `dhi.io` credentials for production verification. Keep public NGINX and any local candidate substitution in test code.

Before registry publication, build a native candidate from the reviewed upstream source with its own tooling. In a separate upstream checkout, select the reviewed source revision, create a Docker Buildx builder with the `docker-container` driver, and run the upstream script with that builder selected via `BUILDX_BUILDER`.

```powershell
./BuildAndPushDocfxImage.ps1 -Tag docfx-oci-test -EngineVersion 1.1.0 -BuildOnly -Platform linux/amd64 -RequireNative -PassThru
```

Use the exact candidate tag from the resulting report as `-LocalBuilder` in `tests/Test-Integration.ps1`. Use `linux/arm64` on a native ARM64 host. See the [upstream build and promotion instructions](https://github.com/codebeltnet/docfx/blob/main/README.md).
