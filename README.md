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

The caller must check out the requested source SHA, install the .NET 10 SDK or newer, and provide any signing key required by the repository's source projects. The action fails immediately with an explicit diagnostic when the SDK is missing. PowerShell 7 and a Docker Engine with Buildx and Linux-container support must be available; Windows hosts must use Linux container mode. The metadata step preserves the repository's optimized restore decision: it uses `--noRestore` only when restore assets exist and are newer than every project and restore input used by the metadata projects.

The OCI archive is validated by `codebeltnet/oci-artifact-verify@v1` before its outputs are exposed. The caller persists it as a workflow artifact and a durable release asset; this action does not publish it.

## Framework views

Set `framework-views` to a settings file in the consumer checkout. The action reads the usual `docfx-config` and packages the staged site with its generated NGINX configuration. Omit the setting to use the existing metadata and Dockerfile flow.

```json
{
  "apiPath": "api/dotnet",
  "defaultFramework": "net11.0",
  "frameworks": ["net11.0", "net10.0", "netstandard2.1", "netstandard2.0"],
  "templatePath": "path/to/pinned/docfx/templates/ms-style"
}
```

`apiPath` is the common URL prefix of the configured metadata destinations. Keep the existing `metadata.dest` values and include `ms-style` in `build.template`. The ordered `frameworks` array controls selector order and fallback from newest to oldest. Omit it to use the default first, followed by the order in which MSBuild declares the other targets. Projects contribute only to their declared TFMs. Resolve duplicate DocFX UIDs between metadata groups as you would for a standard DocFX build.

View IDs support unqualified `net`, `netstandard`, and `netcoreapp` TFMs with dotted versions and compact .NET Framework TFMs such as `net48`. If a project also targets a platform-qualified TFM, list the supported frameworks explicitly.

Use a pinned `templatePath` or set `builderImage` to a pinned DocFX image containing the framework-aware `ms-style` template. The image also renders the site through DocFX. Build content and resources must be rooted under the configuration directory so they can be copied and rendered in isolation. Keep any site-local xref map out of `build.xref` when it could resolve a UID from a different view. Mixed target graphs with a common assembly version can opt into `alignAssemblyVersion` when DocFX needs it to match the identities of compatible dependencies. An independently versioned graph should use native MSBuild/DocFX resolution.

Run the same script from a local checkout of that action revision with PowerShell 7, the .NET 10 SDK or newer (plus the SDKs required by the projects), and a matching DocFX .NET tool installation.

```powershell
& "$actionCheckout/scripts/Build-DocfxFrameworkViews.ps1" `
    -DocfxConfig .docfx/docfx.json -OutputRoot $output `
    -ApiPath api/dotnet -DefaultFramework net11.0 `
    -Framework net11.0,net10.0,netstandard2.1,netstandard2.0 `
    -SharedTemplatePath "$templateCheckout/templates/ms-style"
```

Add `-BuildInContainer` to render with `-BuilderImage`. The output contains the staged site at `site/` and `nginx.conf` beside it. Use `scripts/framework-views.Dockerfile` with a build context containing those two paths. Requests without a view use the default. An unknown view on an API URL returns HTTP 400, and a known view with a missing page returns HTTP 404. The selector resolves fallback before navigating.

Local callers can pass `-MetadataCache` with `-MetadataCacheKey`. Include the source tree, imported build files, filters, restore inputs, and Git revision in the caller's fingerprint. The script also incorporates its own version, the DocFX configuration, the SDK and CLI versions, and the requested framework order. Each view's cached output is checked before reuse.

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
