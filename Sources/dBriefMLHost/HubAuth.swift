/// Hugging Face authentication for model downloads.
///
/// Every model dBrief downloads is public. Given no token, the Hub clients
/// (WhisperKit/SpeakerKit/TTSKit's `HubApi`, swift-transformers' `HubApi`) fall
/// back to `HF_TOKEN` or `~/.cache/huggingface/token` — and Hugging Face answers
/// an expired or revoked token there with 401 even for public repos, so a stale
/// login from the `hf` CLI breaks every download. An explicit empty token
/// bypasses that lookup: each client then sends no (or an empty) `Authorization`
/// header, which Hugging Face accepts for public models.
enum HubAuth {
    static let anonymousToken = ""
}
