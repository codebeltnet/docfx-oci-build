Describe 'DocFX OCI action orchestration' {
    BeforeAll {
        $buildScript = Join-Path $PSScriptRoot '../scripts/build-docfx-oci.ps1'
        $revision = 'a' * 40

        function git {
            $global:LASTEXITCODE = if ($state.Failure -eq 'git') { 1 } else { 0 }
            " $($state.Revision) "
        }

        function docker {
            $state.Calls.Add(($args -join ' '))
            $operation = if ($args[0] -eq 'buildx') { "buildx $($args[1])" } else { $args[0] }
            $global:LASTEXITCODE = if ($operation -eq $state.Failure) { 1 } else { 0 }
            switch ($operation) {
                'create' { if (!$global:LASTEXITCODE) { 'test-container' } }
                'buildx build' {
                    if ($state.Failure -ne 'no archive') {
                        Set-Content -LiteralPath $parameters.OutputPath -Value 'test archive'
                    }
                }
            }
        }

        function dotnet {
            $state.Calls.Add(($args -join ' '))
            $global:LASTEXITCODE = if ($state.Failure -eq 'install') { 1 } else { 0 }
        }

        function docfx {
            $state.Calls.Add(($args -join ' '))
            $global:LASTEXITCODE = if ($state.Failure -eq 'metadata') { 1 } else { 0 }
            New-Item -ItemType Directory -Path api -Force | Out-Null
            Set-Content -LiteralPath api/generated.yml -Value generated
            Set-Content -LiteralPath api/.manifest -Value generated
            Set-Content -LiteralPath api/authored.md -Value authored
        }
    }

    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $workspace = Join-Path $root 'checkout'
        $runnerTemp = Join-Path $root 'temp'
        New-Item -ItemType Directory -Force -Path "$workspace/.docfx", $runnerTemp | Out-Null
        New-Item -ItemType File -Path "$workspace/.docfx/docfx.json", "$workspace/.docfx/Dockerfile.docfx" | Out-Null
        $parameters = @{
            Version = '8.4.3-rc.1'
            Revision = $revision
            OutputPath = Join-Path $root 'site.tar'
            WorkspaceRoot = $workspace
            DocfxConfig = '.docfx/docfx.json'
            Platforms = ' linux/amd64, ,linux/arm64 '
            FrameworkViews = 'true'
        }
        $state = @{ Failure = ''; Revision = $revision; Calls = [Collections.Generic.List[string]]::new() }
        $previousRunnerTemp = $env:RUNNER_TEMP
        $previousGithubOutput = $env:GITHUB_OUTPUT
        $previousPath = $env:PATH
        $previousLocation = $PWD.Path
        $env:RUNNER_TEMP = $runnerTemp
        $env:GITHUB_OUTPUT = Join-Path $root 'github-output'
    }

    AfterEach {
        @(Get-ChildItem -LiteralPath $runnerTemp -Force).Count | Should -Be 0
        $PWD.Path | Should -Be $previousLocation
        $env:PATH | Should -Be $previousPath
        $env:RUNNER_TEMP = $previousRunnerTemp
        $env:GITHUB_OUTPUT = $previousGithubOutput
    }

    It 'exports framework views with the engine Dockerfile, release annotations and detached checksum' {
        Remove-Item Env:RUNNER_TEMP
        & $buildScript @parameters
        $calls = $state.Calls -join "`n"
        $calls | Should -Match 'create --pull always .*target=/docfx-source,readonly.* codebeltnet/docfx:2 '
        $calls | Should -Match 'cp test-container:/opt/docfx/framework-views/framework-views.Dockerfile'
        $calls | Should -Match '--platform linux/amd64,linux/arm64'
        $calls | Should -Match "--annotation index:org.opencontainers.image.version=8\.4\.3-rc\.1 --annotation index:org.opencontainers.image.revision=$revision"
        $calls | Should -Match 'buildx rm docfx-oci-[a-f0-9]{32}'
        $calls | Should -Match 'rm -f test-container'
        $hash = (Get-FileHash -LiteralPath $parameters.OutputPath).Hash.ToLowerInvariant()
        Get-Content -LiteralPath "$($parameters.OutputPath).sha256" | Should -Be "$hash  site.tar"
        Get-Content -LiteralPath $env:GITHUB_OUTPUT | Should -Be @(
            "archive-path=$($parameters.OutputPath)", "checksum-path=$($parameters.OutputPath).sha256"
        )
    }

    It 'uses an absolute custom Dockerfile with the authored Buildx context' {
        $parameters.Dockerfile = "$workspace/.docfx/Dockerfile.docfx"
        $parameters.DocfxConfig = "$workspace/.docfx/docfx.json"
        & $buildScript @parameters
        $calls = $state.Calls -join "`n"
        $calls | Should -Not -Match 'cp .*framework-views.Dockerfile'
        $calls | Should -Match ([regex]::Escape("--file $([IO.Path]::GetFullPath($parameters.Dockerfile))"))
        $calls | Should -Match '--build-context docfx-source='
    }

    It 'uses the requested legacy CLI, ordinary restore and the conventional Dockerfile' {
        $parameters.Remove('FrameworkViews')
        $parameters.DocfxVersion = '2.80.1'
        & $buildScript @parameters
        $state.Calls | Should -Contain 'metadata docfx.json'
        ($state.Calls -join "`n") | Should -Match 'tool install --tool-path .+ docfx --version 2.80.1'
        ($state.Calls -join "`n") | Should -Match '\.docfx[/\\]Dockerfile.docfx'
        "$workspace/.docfx/api/authored.md" | Should -Exist
        "$workspace/.docfx/api/generated.yml" | Should -Not -Exist
        "$workspace/.docfx/api/.manifest" | Should -Not -Exist
    }

    It 'rejects <case> before starting Docker without replacing existing files' -ForEach @(
        @{ case = 'invalid opt-in'; field = 'FrameworkViews'; value = 'yes'; error = '*framework-views*' }
        @{ case = 'invalid version'; field = 'Version'; value = 'v8.4.3'; error = '*SemVer*' }
        @{ case = 'abbreviated revision'; field = 'Revision'; value = 'a'; error = '*40-character*' }
        @{ case = 'wrong revision'; field = 'Revision'; value = ('b' * 40); error = '*requested release revision*' }
        @{ case = 'missing configuration'; field = 'DocfxConfig'; value = 'missing.json'; error = '*configuration was not found*' }
        @{ case = 'missing Dockerfile'; field = 'Dockerfile'; value = 'missing.Dockerfile'; error = '*Dockerfile was not found*' }
        @{ case = 'one platform'; field = 'Platforms'; value = 'linux/amd64'; error = '*must include linux/amd64 and linux/arm64*' }
    ) {
        $parameters[$field] = $value
        { & $buildScript @parameters } | Should -Throw $error
        $state.Calls.Count | Should -Be 0
        $env:GITHUB_OUTPUT | Should -Not -Exist
    }

    It 'rejects a DocFX configuration outside the checkout' {
        $parameters.DocfxConfig = Join-Path $root 'external.json'
        New-Item -ItemType File -Path $parameters.DocfxConfig | Out-Null
        { & $buildScript @parameters } | Should -Throw '*inside the checked-out workspace*'
        $state.Calls.Count | Should -Be 0
    }

    It 'preserves an existing <suffix> output' -ForEach @(
        @{ suffix = ''; error = '*archive output already exists*' }
        @{ suffix = '.sha256'; error = '*checksum output already exists*' }
    ) {
        $existing = "$($parameters.OutputPath)$suffix"
        Set-Content -LiteralPath $existing -Value existing
        { & $buildScript @parameters } | Should -Throw $error
        Get-Content -LiteralPath $existing | Should -Be existing
        $state.Calls.Count | Should -Be 0
    }

    It 'requires a GitHub output destination before working' {
        Remove-Item Env:GITHUB_OUTPUT
        { & $buildScript @parameters } | Should -Throw '*GITHUB_OUTPUT is not available*'
        $state.Calls.Count | Should -Be 0
    }

    It 'cleans up and leaves no outputs after <operation> fails' -ForEach @(
        @{ operation = 'git'; error = '*resolve the checked out source revision*' }
        @{ operation = 'create'; error = '*upstream release has published this tag*' }
        @{ operation = 'start'; error = '*framework views failed*'; container = $true }
        @{ operation = 'cp'; error = '*Could not retrieve*'; container = $true }
        @{ operation = 'buildx version'; error = '*Buildx is not available*'; container = $true }
        @{ operation = 'buildx create'; error = '*Could not create a Docker Buildx builder*'; container = $true }
        @{ operation = 'buildx inspect'; error = '*Could not start*'; container = $true; builder = $true }
        @{ operation = 'buildx build'; error = '*docker login dhi.io*'; container = $true; builder = $true }
        @{ operation = 'no archive'; error = '*without creating the expected OCI archive*'; container = $true; builder = $true }
        @{ operation = 'install'; error = '*Could not install DocFX CLI*'; legacy = $true }
        @{ operation = 'metadata'; error = '*metadata generation failed*'; legacy = $true }
    ) {
        $state.Failure = $operation
        if ($legacy) { $parameters.FrameworkViews = 'false' }
        { & $buildScript @parameters } | Should -Throw $error
        $parameters.OutputPath | Should -Not -Exist
        "$($parameters.OutputPath).sha256" | Should -Not -Exist
        $env:GITHUB_OUTPUT | Should -Not -Exist
        ($state.Calls -contains 'rm -f test-container') | Should -Be ([bool]$container)
        [bool]($state.Calls -like 'buildx rm *') | Should -Be ([bool]$builder)
    }

    It 'removes artifacts when the GitHub output file cannot be written' {
        $env:GITHUB_OUTPUT = Join-Path $root 'missing-folder/github-output'
        { & $buildScript @parameters } | Should -Throw
        $parameters.OutputPath | Should -Not -Exist
        "$($parameters.OutputPath).sha256" | Should -Not -Exist
    }
}
