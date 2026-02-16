# Memory Optimization & Stability Fixes

## Problem Summary

Your MacBook Air M3 with 16GB unified memory was experiencing **WindowServer crashes** and system instability when using LocalLLM features. This was caused by:

- **Qwen 2.5 7B model**: ~5GB (31% of total RAM)
- **WhisperKit model**: ~1GB (6% of total RAM)
- **Combined**: 6GB (37.5% of RAM) when both loaded

On unified memory architecture, GPU and CPU share the same pool, leaving insufficient memory for WindowServer and other apps.

## Root Causes Identified

1. ❌ **NO MEMORY PRESSURE MONITORING** - App didn't respond to system memory warnings
2. ❌ **MODELS STAYED LOADED** - 6GB remained in memory indefinitely
3. ❌ **UNSAFE CLEANUP** - Stream cancellation could skip model unloading
4. ❌ **NO PRE-ALLOCATION CHECKS** - Models loaded without verifying available memory
5. ❌ **TEMP FILE ACCUMULATION** - Converted WAV files not cleaned up
6. ❌ **NO OPERATION LIMITS** - Inference could run indefinitely
7. ❌ **MISSING AUTORELEASEPOOL** - Temporary objects accumulated

---

## Fixes Implemented

### 1. **New: MemoryPressureMonitor Service**
**File**: `Sources/dBrief/Services/MemoryPressureMonitor.swift`

Monitors system memory pressure and triggers automatic cleanup:

- ✅ **Warning Level**: Unloads AI models
- ✅ **Critical Level**: Aggressive cleanup + cache purging
- ✅ **Pre-Allocation Check**: Verifies sufficient memory before loading models
- ✅ **Memory Statistics**: Tracks free/used/total memory

**Integration**: Starts automatically in `AppContext.init()` and registers cleanup handler.

---

### 2. **MLXInsightsService Protections**
**File**: `Sources/dBrief/Services/MLXInsightsService.swift`

**Changes:**
- ✅ **Pre-load check**: Requires **8GB free** before loading Qwen (5GB model + 3GB buffer)
- ✅ **Aggressive cleanup**: Calls `unload()` immediately after every inference
- ✅ **Stream cancellation fix**: Ensures cleanup happens even when stream is cancelled
- ✅ **Reduced token limits**:
  - `maxTokens`: 2048 → **1536** (-25%)
  - `maxKVSize`: 16384 → **12288** (-25%)
- ✅ **Error handling**: Cleanup on all error paths

---

### 3. **WhisperKitTranscriptionService Protections**
**File**: `Sources/dBrief/Services/WhisperKitTranscriptionService.swift`

**Changes:**
- ✅ **Pre-load check**: Requires **2GB free** before loading WhisperKit (1GB model + 1GB buffer)
- ✅ **Temp file cleanup**: Explicitly deletes converted WAV files after transcription
- ✅ **Error handling**: Cleanup on all error paths

---

### 4. **LocalAIPluginService Enhanced Cleanup**
**File**: `Sources/dBrief/Services/LocalAIPluginService.swift`

**Changes:**
- ✅ **Stream cancellation fix**: Added `onTermination` handler with cleanup
- ✅ **Memory pressure handler**: New `purgeModelsOnMemoryPressure()` method
- ✅ **Forced unload**: Bypasses mutex for immediate cleanup during memory pressure
- ✅ **Error path cleanup**: Unloads both services on any error

---

### 5. **RecordingManager Integration**
**File**: `Sources/dBrief/Services/RecordingManager.swift`

**Changes:**
- ✅ **Memory pressure handler**: New `handleMemoryPressure()` method
- ✅ **Automatic cleanup**: Triggered by MemoryPressureMonitor

---

### 6. **AppContext Integration**
**File**: `Sources/dBrief/App/DBriefApp.swift`

**Changes:**
- ✅ **MemoryPressureMonitor**: Created and started at app launch
- ✅ **Cleanup registration**: RecordingManager registered for memory pressure callbacks

---

## User-Facing Improvements

### Before
- 🔴 WindowServer crashes
- 🔴 System hangs
- 🔴 6GB memory locked indefinitely
- 🔴 No warnings or safety checks

### After
- ✅ **Pre-flight checks**: Warns if insufficient memory *before* loading
- ✅ **Automatic cleanup**: Models unload immediately after use
- ✅ **Memory pressure response**: Unloads models when system is stressed
- ✅ **Better error messages**: Clear guidance (e.g., "Need at least 8GB free memory. Close other apps or use Remote AI engine instead.")
- ✅ **Temp file cleanup**: No disk space waste from converted audio files
- ✅ **Reduced token usage**: 25% less memory per inference

---

## Error Messages You'll See

If memory is insufficient, you'll now get clear errors instead of crashes:

**Qwen Model:**
```
Insufficient memory to load Qwen 2.5 model.
Need at least 8GB free memory.
Close other apps or use Remote AI engine instead.
```

**WhisperKit Model:**
```
Insufficient memory to load WhisperKit model.
Need at least 2GB free memory.
Close other apps or use Remote transcription instead.
```

---

## Testing Recommendations

1. **Before using local models**: Check Activity Monitor → Memory tab
2. **Expected behavior**:
   - Models load → process → unload immediately
   - Memory freed within seconds of completion
3. **If you see warnings**: Close other apps or switch to Remote AI endpoints
4. **Monitor logs**: Check Console.app for "Memory pressure" messages

---

## Technical Details

### Memory Requirements

| Model | Size | Free RAM Required | Notes |
|-------|------|-------------------|-------|
| Qwen 2.5 7B (4-bit) | ~5GB | **8GB** | Includes 3GB buffer |
| WhisperKit (small) | ~1GB | **2GB** | Includes 1GB buffer |
| Both simultaneously | ~6GB | **10GB** | Avoided by cleanup |

### Cleanup Timing

- **Normal completion**: `unload()` called immediately
- **Stream cancelled**: `onTermination` triggers cleanup
- **Error occurred**: `defer`/`catch` blocks ensure cleanup
- **Memory pressure**: Forced unload within milliseconds

---

## Build Status

✅ **Compiles successfully**
✅ **All diagnostics resolved**
✅ **No breaking changes to existing functionality**

---

## Next Steps

1. **Test with real recordings** - Monitor memory usage in Activity Monitor
2. **Adjust thresholds if needed** - Current: 8GB for Qwen, 2GB for Whisper
3. **Monitor logs** - Check Console.app for any memory pressure events
4. **Consider upgrading RAM** - 32GB recommended for frequent local AI use on M3

---

**Date**: February 16, 2026
**System**: MacBook Air M3, 16GB RAM
**Models Affected**: Qwen 2.5 7B, WhisperKit (whisper-small)
