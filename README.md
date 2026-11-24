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
  # Workspace-relative Dockerfile. This default applies to builds without framework views.
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

Set `framework-views` to a settings file in the consumer checkout and choose a Dockerfile explicitly. The usual `docfx-config` remains authoritative for project mappings and metadata destinations. Omit `framework-views` to use the existing metadata and Dockerfile flow.

```json
{
  "apiPath": "api",
  "defaultFramework": "net11.0",
  "builderImage": "codebeltnet/docfx:<version>@sha256:<digest>"
}
```

`apiPath` is the shared URL root. For example, `api` covers `api/dotnet`, `api/extensions/dotnet`, `api/aspnet`, and `api/extensions/aspnet` without changing their `metadata.dest` values. Include `ms-style` in `build.template`. MSBuild supplies the declared TFMs, and each project contributes only to its declared targets. The selector starts with the default framework followed by the other declared targets in discovery order. Set the optional `frameworks` array to control the supported views and their fallback order. Resolve duplicate DocFX UIDs between metadata groups as you would for a standard DocFX build.

View IDs support unqualified `net`, `netstandard`, and `netcoreapp` TFMs with dotted versions and compact .NET Framework TFMs such as `net48`. If a project also targets a platform-qualified TFM, list the supported frameworks explicitly.

Use a digest-pinned, framework-aware `codebeltnet/docfx` image for `builderImage`. It supplies the `ms-style` template and renders the site. To render on the host, replace `builderImage` with `"templatePath": "../.docfx-deps/ms-style"` and extract `templates/ms-style` from a separately pinned [`codebeltnet/docfx` source archive](https://github.com/codebeltnet/docfx). The template path is relative to the settings file, and can also be used with a builder image to test an unreleased template. The host uses DocFX **2.81.0** for project discovery and metadata. This version pins the public DocFX file-mapping API used by the resolver. Install the SDKs required by the source projects. The resolver selects .NET 10 or later independently of any consumer `global.json`.

Keep build content and resources under the DocFX configuration directory so they can be copied and rendered in isolation. Keep any site-local xref map out of `build.xref` when it could resolve a UID from a different view. Mixed target graphs with a common assembly version can opt into `alignAssemblyVersion` when DocFX needs it to match the identities of compatible dependencies. An independently versioned graph should use native MSBuild/DocFX resolution.

### Use the same release locally and in CI

Pin the full commit SHA of a release that includes framework views. GitHub distributes the release's source as a ZIP. The composite action uses the scripts already included at that SHA, and a standalone consumer can extract those same files wherever it keeps build tools. The commit pins the extracted files even if GitHub regenerates the ZIP. Cross-repository integration tests can use unpublished checkouts of the same files. [GitHub source archive guarantees](https://docs.github.com/en/repositories/working-with-files/using-files/downloading-source-code-archives#stability-of-source-code-archives)

```yaml
- uses: codebeltnet/docfx-oci-build@<full-release-commit-sha>
  with:
    version: ${{ needs.build.outputs.version }}
    revision: ${{ github.sha }}
    output-path: ${{ runner.temp }}/docfx-site.oci.tar
    framework-views: .docfx/framework-views.json
    dockerfile: bundled-framework-views
```

From the consumer root, use PowerShell 7 and the same settings file. Use Docker when rendering with `builderImage`.

```powershell
$releaseCommit = '<full-release-commit-sha>'
$tools = Join-Path ([IO.Path]::GetTempPath()) "docfx-views-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tools | Out-Null
Invoke-WebRequest "https://codeload.github.com/codebeltnet/docfx-oci-build/zip/$releaseCommit" -OutFile "$tools/source.zip"
Expand-Archive -LiteralPath "$tools/source.zip" -DestinationPath $tools
dotnet tool install --tool-path "$tools/bin" docfx --version 2.81.0
if ($LASTEXITCODE -ne 0) { throw 'Could not install DocFX 2.81.0.' }
$env:PATH = "$tools/bin$([IO.Path]::PathSeparator)$env:PATH"
& "$tools/docfx-oci-build-$releaseCommit/scripts/Build-DocfxFrameworkViews.ps1" `
    -DocfxConfig .docfx/docfx.json -SettingsPath .docfx/framework-views.json `
    -OutputRoot "$tools/output"
```

Local callers can pass `-MetadataCache` with `-MetadataCacheKey`. Include the source tree, imported build files, filters, restore inputs, and Git revision in the caller's fingerprint. The generator also hashes the shared metadata implementation, DocFX configuration, resolved file mappings, resolver and project SDK versions, DocFX version, and framework settings that affect metadata. Each view's cached output is checked before reuse.

### Choose the OCI packaging

The framework generator outputs the staged `site/` and generated `nginx.conf`. When the action packages the site, its primary build context contains those two paths.

- Set `dockerfile: bundled-framework-views` to adopt the bundled NGINX configuration and image checks. This explicitly replaces the consumer's image, NGINX configuration, and Dockerfile verification. The bundled Dockerfile checks for the framework manifest and runs `nginx -t`.
- Set `dockerfile` to a compatible workspace-relative file to preserve consumer-specific image behavior and verification. Use `COPY site/ ...` for the rendered files, and install `nginx.conf` or preserve its routing and cache behavior in your own configuration. The action supplies the directory containing `docfx.json` as the named Buildx context `docfx-source`. Use `COPY --from=docfx-source ...` for consumer-owned configuration, verification scripts, and verification inputs. Validate the staged site and the final server configuration in the Dockerfile. A legacy Dockerfile that runs its own single `docfx build` needs to be adapted to consume the staged site.

Both options keep the release revision check, required `linux/amd64` and `linux/arm64` platforms, OCI version and revision annotations, detached SHA-256 checksum, and archive verification. The generated NGINX configuration serves file URLs and slash-terminated directory indexes under the selected view. Requests without a view use the default. An unknown API view returns HTTP 400 and a page or directory index unavailable in the selected view returns HTTP 404. The selector resolves fallback before navigation.

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
