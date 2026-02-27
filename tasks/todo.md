# Backlog

## Bugs

### ~~Bug #1: Remote transcription fails on first attempt~~ ✅ FIXED
- Root cause: format probe timeout (12s) too tight for cold connections (TLS handshake + server model loading)
- Fix: increased probe timeout from 12s to 30s

## Improvements

### ~~Improvement #1: Persist transcription before LLM analysis~~ ✅ DONE

### ~~Improvement #2: Laptop Mode — offline task queue~~ ✅ DONE
