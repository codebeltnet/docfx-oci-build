# AGENTS.md

- Keep this repository focused on building and verifying the consumer documentation OCI archive. Upstream DocFX owns framework discovery, generation and the bundled framework-view Dockerfile. Consumer workflows own publication and promotion.
- Use the stable Codebelt builder tag `codebeltnet/docfx:2` in `scripts/build-docfx-oci.ps1` with `--pull always`. Verify both Linux manifests and exercise the builder contract in integration tests. Use version tags for Codebelt and trusted third-party GitHub Actions. Use full commit SHAs for other third-party actions and preserve the hardened Docker base's digest pin.
- Preserve the Boolean `framework-views` opt-in, conventional DocFX config path, legacy CLI and restore behavior, and explicit custom Dockerfile support.
- Keep the framework checkout mount read-only. The writable container copy must retain Git metadata and all authored build inputs. Keep runner credentials and files outside the checkout out of the builder.
- Verify the consumer source revision, archive checksum, OCI identity and both target platforms. Return paths and a digest only after verification. Clean up build resources and failed output files.
- Keep test substitutions in `tests/`. Fork PRs use public GHCR NGINX for bundled packaging tests. Production packaging uses the upstream Dockerfile default and the caller's Docker authentication.
- Use PowerShell 7 for orchestration. Run the Docker-stub contract checks and require 100% measured Pester command coverage of refactored orchestration. Run the real Docker integration separately. See [validation commands](README.md#validation) and [builder validation](RELEASE.md#builder-validation).
