# CodeBridge

**Connect your codebase to AI. Bring changes back safely.**

CodeBridge is a developer toolkit for bridging source code and AI workflows.

It helps developers extract, filter, and package codebase context for Large Language Models (LLMs), then validate, apply, and recover AI-generated code changes through a controlled workflow.

Instead of relying on a specific AI provider or editor, CodeBridge provides a platform-oriented toolkit that works with your existing development environment.

## Why CodeBridge?

Working with AI on an existing codebase involves two challenges:

- **Providing context:** Preparing relevant source code without overwhelming the model with unnecessary files.
- **Applying changes safely:** Bringing AI-generated changes back into the project while preserving control over the result.

CodeBridge aims to address both sides of this workflow.

## Core Capabilities

### 1. Codebase Context Preparation
- Extract source code from project directories.
- Filter files and directories.
- Exclude unnecessary files and generated content.
- Prepare structured context for AI tools.
- Support multiple export formats.

### 2. AI-Generated Change Integration
- Import AI-generated diffs and patches.
- Validate changes before applying them.
- Apply changes to the target codebase.
- Detect and report patch application issues.

### 3. Change Safety and Recovery
- Create backups before applying changes.
- Preserve previous project states.
- Support rollback and recovery workflows.

## Project Structure

```text
CodeBridge/
├── docs/
│   └── platforms/
│       ├── linux/
│       └── windows/
├── examples/
│   └── diff.example.txt
├── platforms/
│   ├── linux/
│   │   └── codebridge.sh
│   └── windows/
│       ├── codebridge.cmd
│       ├── codebridge-core.ps1
│       ├── codebridge-apply.cmd
│       └── codebridge.sh
├── LICENSE
└── README.md
```

## Platform Support

| Platform | Implementation | Status |
|---|---|---|
| Linux | Bash | In development |
| Windows | CMD / PowerShell | In development |

Platform compatibility and supported environments will be documented as they are verified.

## Getting Started

Platform-specific setup and usage instructions:

- [Linux Documentation](docs/platforms/linux/README.md)
- [Windows Documentation](docs/platforms/windows/README.md)

## Examples

Example patch files are available in the [`examples/`](examples/) directory.

## Design Principles

- **LLM-Agnostic:** No dependency on a specific AI provider.
- **Developer-Controlled:** Changes are reviewed and validated before integration.
- **Safety First:** Backups and recovery are part of the workflow.
- **Cross-Platform:** Platform-specific implementations share a consistent purpose.
- **Transparent:** Operations should be predictable and understandable.

## Roadmap

- [ ] Improve codebase discovery and extraction.
- [ ] Add configurable filtering and export formats.
- [ ] Add token estimation and context optimization.
- [ ] Improve unified diff and patch validation.
- [ ] Strengthen backup and rollback mechanisms.
- [ ] Expand platform support.
- [ ] Add automated tests and CI workflows.

## Contributing

Contributions, bug reports, and suggestions are welcome.

Before submitting changes, please review the platform-specific documentation and ensure that existing workflows remain functional.

## License

This project is licensed under the terms of the [MIT License](LICENSE).
