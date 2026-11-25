# Build DocFX OCI Artifact from Codebelt

Builds documentation from the checked-out revision and exports the site as a verified multi-platform OCI archive. The action verifies that the workspace is at the requested release SHA and uses the explicit release version as the OCI reference and version annotation.

> This action is part of the Codebelt umbrella and ensures a consistent way of:
>
> - Defining your CI/CD pipeline
> - Structuring your repository
> - Keeping your codebase small and feasible
> - Writing clean and maintainable code
> - Deploying your code to different environments
> - Automating as much as possible
>
> A paved path to excel as a DevSecOps Engineer.

## Usage

To use this action in your GitHub repository, you can follow these steps:

```yaml
uses: codebeltnet/docfx-oci-build@v1
```

### Inputs

```yaml
with:
  # Human-selected SemVer release version without the v prefix.
  version:
  # Full 40-character commit SHA being released.
  revision:
  # Absolute path for the OCI archive; a .sha256 file is created alongside it.
  output-path:
  # DocFX configuration path relative to the workspace.
  docfx-config: .docfx/docfx.json
  # Workspace-relative Dockerfile. This default applies to builds without framework views.
  dockerfile: .docfx/Dockerfile.docfx
  # Legacy CLI selection. Framework views use the builder image's CLI.
  docfx-version: 2.81.0
  # Boolean opt-in for native framework views.
  framework-views: false
  # Comma-separated target platform list for the OCI image.
  platforms: linux/amd64,linux/arm64
```

### Outputs

```yaml
outputs:
  # Absolute path to the verified OCI archive.
  archive-path:
  # Absolute path to the archive SHA-256 file.
  checksum-path:
  # SHA-256 digest of the embedded OCI image index.
  digest:
```

The caller must check out the requested source SHA, install the .NET 10 SDK or newer, and provide any signing key required by the repository's source projects. The action fails immediately with an explicit diagnostic when the SDK is missing. The runner needs PowerShell 7, Docker Engine and Buildx with Linux-container support. Legacy builds install the CLI selected by `docfx-version` on the runner and run standard `docfx metadata` with DocFX and MSBuild managing restores. They retain access to the runner's NuGet configuration and credential providers.

The OCI archive is validated by `codebeltnet/oci-artifact-verify@v1` before the action returns any outputs. Use a fresh output path for each build. Persist and promote that same verified documentation archive and detached checksum in your release workflow.

## Framework views

Set `framework-views: true` and keep `docfx-config` in the checked-out workspace. The generator derives the API root from DocFX metadata destinations and discovers frameworks from MSBuild. Omitting the input or setting it to `false` uses the legacy metadata and Dockerfile flow.

```yaml
- uses: codebeltnet/docfx-oci-build@v1
  with:
    version: ${{ needs.release_preflight.outputs.version }}
    revision: ${{ needs.release_preflight.outputs.sha }}
    output-path: ${{ runner.temp }}/docfx.oci.tar
    framework-views: true
```

Framework views use `codebeltnet/docfx:2.81.0-v1.1.0`. The tag selects DocFX CLI 2.81.0 and Codebelt engine 1.1.0 independently of the consumer release `version` and the legacy-only `docfx-version` input. The action logs the tag and pulls it from Docker Hub. The upstream builder is the tool image that generates the site. The OCI archive returned by this action contains the consumer's documentation and carries the consumer's release version and source revision. See the [release notes and builder update procedure](RELEASE.md).

The builder reads `.docfx/docfx.json` by default and uses MSBuild to discover the target frameworks. The checkout is mounted read-only and copied inside the container, including Git metadata, signing keys in the checkout, MSBuild imports, project references, templates and content. The builder must contain the SDKs required by the projects and any `global.json` constraints. Runner NuGet credentials, external credential providers, the runner's home directory, and files outside the checkout are unavailable inside the isolated builder. Framework-view consumers need restore sources accessible from the builder. [DocFX framework-view documentation](https://github.com/codebeltnet/docfx/tree/main/framework-views)

### Choose the OCI packaging

The framework engine supplies `site/` and `nginx.conf` as the primary Buildx context.

- Omit `dockerfile` to use the standard Dockerfile from the same builder image. It uses a digest-pinned Docker Hardened Image from `dhi.io`, checks the generated framework manifest and runs `nginx -t`.
- Set `dockerfile` to a compatible workspace-relative file to keep consumer-owned packaging and verification. Use `COPY site/ ...` for the rendered files. Install `nginx.conf` or retain its routing and cache behavior in your own configuration. The named `docfx-source` Buildx context points to the directory containing `docfx.json`. Use `COPY --from=docfx-source ...` for consumer configuration, verification scripts and verification inputs.

Both options validate the checked-out release revision, export `linux/amd64` and `linux/arm64`, annotate the OCI index with the release version and revision, and write and verify a detached SHA-256 checksum.

Authenticate to `dhi.io` before this action when the registry requires credentials. Run `docker login dhi.io` or use a registry login action with credentials stored in the caller's repository or environment secrets. Run the login and build with the same Docker configuration and credential helpers. If you set `DOCKER_CONFIG`, make it available to both steps. The local Buildx client uses these credentials for the registry session. For HTTP 401 or 403 errors, check the login host, pull access to the image, and that the credential helper is available on the runner. Custom Dockerfiles may require login to their own base-image registries.

## Examples

### Build a DocFX OCI archive with the default configuration

```yaml
- name: Build DocFX OCI artifact
  uses: codebeltnet/docfx-oci-build@v1
  with:
    version: ${{ needs.build.outputs.version }}
    revision: ${{ github.sha }}
    output-path: ${{ runner.temp }}/docfx-site.oci.tar
```

### Build a DocFX OCI archive with custom paths

```yaml
- name: Build DocFX OCI artifact
  uses: codebeltnet/docfx-oci-build@v1
  with:
    version: ${{ needs.build.outputs.version }}
    revision: ${{ github.sha }}
    output-path: ${{ runner.temp }}/docs/custom-docfx-site.oci.tar
    docfx-config: docs/docfx/docfx.json
    dockerfile: docs/docfx/Dockerfile
```

## Validation

The PR workflow checks syntax and contracts, enforces 100% measured PowerShell command coverage of the orchestration script, and exports and verifies real two-platform documentation archives. It uses the public GHCR NGINX base through the bundled Dockerfile's existing build argument in test code. The **Required quality gate** combines the workflow, unit and integration jobs. The authenticated production Dockerfile is checked separately with its hardened default.

```powershell
Install-PSResource Pester -Version 5.7.1 -Repository PSGallery -TrustRepository -Scope CurrentUser
pwsh -NoProfile -File ./tests/Invoke-UnitTests.ps1
pwsh -NoProfile -File ./tests/Test-ActionContract.ps1
actionlint
```

For local Docker validation, put a clone of `codebeltnet/oci-artifact-verify` alongside this repository and set `$verifier` to the full path of its `verify-oci-artifact.cs`. After publication the integration script pulls the approved builder tag. Before publication use the verified local candidate from the [release procedure](RELEASE.md) by passing `-LocalBuilder` to the test script.

```powershell
$testRoot = [IO.Path]::GetTempPath()
./tests/Test-Integration.ps1 -Scenario Bundled -OutputPath (Join-Path $testRoot 'docfx-bundled.oci.tar') -VerifierPath $verifier
./tests/Test-Integration.ps1 -Scenario Custom -OutputPath (Join-Path $testRoot 'docfx-custom.oci.tar') -VerifierPath $verifier
./tests/Test-Integration.ps1 -Scenario Legacy -OutputPath (Join-Path $testRoot 'docfx-legacy.oci.tar') -VerifierPath $verifier
docker login dhi.io
./tests/Test-Integration.ps1 -Scenario Production -OutputPath (Join-Path $testRoot 'docfx-production.oci.tar') -VerifierPath $verifier
```

Supply `-ConsumerRoot` with a clean, prepared Cuemon checkout to run acceptance with its authored `.docfx/docfx.json`. Use the signing key provisioned for that checkout.

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE).

> [!TIP]
> To learn more about the Codebelt experience and offerings, visit our [organization page](https://github.com/codebeltnet) on GitHub.
