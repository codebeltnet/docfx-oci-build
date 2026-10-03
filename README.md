# Build DocFX OCI Artifact from Codebelt

Generates DocFX metadata and exports the site as a multi-platform OCI archive from the checked out revision. The action verifies that the workspace is at the requested release SHA and uses the explicit release version as the OCI reference and version annotation.

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
  # DocFX image Dockerfile path relative to the workspace.
  dockerfile: .docfx/Dockerfile.docfx
  # DocFX CLI version used to generate metadata.
  docfx-version: 2.78.5
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

The caller must check out the requested source SHA, install the .NET 10 SDK or newer, and provide any signing key required by the repository's source projects. The action fails immediately with an explicit diagnostic when the SDK is missing. PowerShell 7 and a Docker Engine with Buildx and Linux-container support must be available; Windows hosts must use Linux container mode. The metadata step preserves the repository's optimized restore decision: it uses `--noRestore` only when restore assets exist and are newer than every project and restore input used by the metadata projects.

The OCI archive is validated by `codebeltnet/oci-artifact-verify@v1` before its outputs are exposed. The caller persists it as a workflow artifact and a durable release asset; this action does not publish it.

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
