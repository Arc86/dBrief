# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

VoiceRecorder is a Swift Package Manager (SPM) executable target using Swift 6.2. The project follows standard Swift package conventions.

## Building and Running

- **Build the project**: `swift build`
- **Run the executable**: `swift run`
- **Build for release**: `swift build -c release`
- **Clean build artifacts**: `swift package clean`

## Testing

- **Run tests**: `swift test`
- **Run specific test**: `swift test --filter <TestName>`

## Project Structure

- `Package.swift` - Swift Package Manager manifest defining the executable target
- `Sources/VoiceRecorder/` - Main source directory containing the executable entry point
- `.build/` - Build artifacts (ignored by git)

## Swift Version

This project requires Swift 6.2 or later as declared in the Package.swift manifest.
