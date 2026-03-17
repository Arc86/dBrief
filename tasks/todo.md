# Backlog

## Bugs

### ~~Bug #1: Remote transcription fails on first attempt~~ ✅ FIXED
- Root cause: format probe timeout (12s) too tight for cold connections (TLS handshake + server model loading)
- Fix: increased probe timeout from 12s to 30s

## Improvements

### ~~Improvement #1: Persist transcription before LLM analysis~~ ✅ DONE

### ~~Improvement #2: Laptop Mode — offline task queue~~ ✅ DONE

### Improvement #3: Switch MLX model from Qwen 2.5 7B to Qwen3 4B

**Why**: Qwen2.5-7B-4bit (~4.5GB) is too slow for practical on-device use. Qwen3-4B-4bit (~2.3GB) is roughly half the size, loads faster, and generates tokens faster while still being capable enough for summary/action-item extraction.

**Model**: `mlx-community/Qwen3-4B-Instruct-2507-4bit`

**Changes**:

1. **`MLXInsightsService.swift`**
   - Change `modelID` from `"mlx-community/Qwen2.5-7B-Instruct-4bit"` to `"mlx-community/Qwen3-4B-Instruct-2507-4bit"`
   - Lower memory limit cap from 12GB to 8GB (smaller model needs less headroom)

2. **`RecordingManager.swift`** (2 places)
   - Update `Endpoint(name:)` from `"Qwen 2.5 Local"` to `"Qwen3 4B Local"`
   - Update `modelName:` from `"Qwen2.5-7B-Instruct-4bit (MLX)"` to `"Qwen3-4B-Instruct-2507-4bit (MLX)"`

3. **`AppSettings.swift`**
   - Update `.qwenLocal` display name from `"Qwen 2.5 Local"` to `"Qwen3 4B Local"`

4. **`SettingsAITab.swift`**
   - Update description text to reference Qwen3 4B

5. **`RecordingManager.swift`** (processing step labels, 4 places)
   - Update `"(Qwen 2.5 local)"` → `"(Qwen3 4B local)"`

6. **Purge old model** — user should purge the old 7B model from settings to reclaim ~4.5GB disk space

**No prompt changes needed** — `mlx-swift-lm`'s `ChatSession` auto-applies the model's chat template from the HuggingFace config.
