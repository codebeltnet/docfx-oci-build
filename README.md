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
  # Optional JSON settings path for native framework views.
  framework-views:
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

The caller must check out the requested source SHA, install the .NET 10 SDK or newer, and provide any signing key required by the repository's source projects. The action fails immediately with an explicit diagnostic when the SDK is missing. PowerShell 7 and a Docker Engine with Buildx and Linux-container support must be available; Windows hosts must use Linux container mode. Legacy builds run standard `docfx metadata` and let DocFX and MSBuild manage restores.

The OCI archive is validated by `codebeltnet/oci-artifact-verify@v1` before its outputs are exposed. The caller persists it as a workflow artifact and a durable release asset; this action does not publish it.

## Framework views

Set `framework-views` to the consumer's existing settings file and choose a Dockerfile explicitly. Keep the settings file and `docfx-config` in the checked-out workspace. Omitting `framework-views` keeps the legacy metadata and Dockerfile flow.

```yaml
- uses: codebeltnet/docfx-oci-build@<full-action-release-commit-sha>
  with:
    version: ${{ needs.build.outputs.version }}
    revision: ${{ github.sha }}
    output-path: ${{ runner.temp }}/docfx-site.oci.tar
    framework-views: .docfx/framework-views.json
    dockerfile: bundled-framework-views
```

The action pulls `codebeltnet/docfx:2` and runs its generator, CLI and default `ms-style` template. Set `builderImage` in the framework-view settings to use another compatible Docker image reference, such as a published digest or a locally built candidate. The selected image must include the shared engine and the SDKs the consumer projects require. The generator builds from a writable copy inside the container, with the runner's checkout mounted read-only. [DocFX framework-view documentation](https://github.com/codebeltnet/docfx/tree/main/framework-views)

### Choose the OCI packaging

The framework engine supplies `site/` and `nginx.conf` as the primary Buildx context.

- Set `dockerfile: bundled-framework-views` to use the standard Dockerfile from the same builder image. It checks the framework manifest and runs `nginx -t`.
- Set `dockerfile` to a compatible workspace-relative file to keep consumer-owned packaging and verification. Use `COPY site/ ...` for the rendered files. Install `nginx.conf` or retain its routing and cache behavior in your own configuration. The named `docfx-source` Buildx context points to the directory containing `docfx.json`. Use `COPY --from=docfx-source ...` for consumer configuration, verification scripts and verification inputs.

Both options validate the checked-out release revision, export `linux/amd64` and `linux/arm64`, annotate the OCI index with the release version and revision, and write and verify a detached SHA-256 checksum.

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

## Contributing to Build DocFX OCI Artifact from Codebelt

Contributions are welcome! Feel free to submit issues, feature requests, or pull requests to help improve this action.

## License

This project is licensed under the MIT License - see the [LICENSE](../LICENSE) file for details.

> [!TIP]
> To learn more about the Codebelt experience and offerings, visit our [organization page](https://github.com/codebeltnet) on GitHub.
