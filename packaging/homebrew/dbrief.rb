# Homebrew formula for dBrief — builds from source on the user's Mac.
#
# Building locally means the resulting app is never quarantined, so macOS
# Gatekeeper does not block it (dBrief is distributed outside the Apple
# Developer Program and is therefore unsigned/un-notarized).
#
# To publish: copy this file into a tap repo `Arc86/homebrew-dbrief` at
# `Formula/dbrief.rb`, then users run:
#
#     brew install Arc86/dbrief/dbrief
#
# After tagging a release, update `url` and `sha256` for the new version:
#
#     curl -L -o /tmp/dbrief.tar.gz \
#       https://github.com/Arc86/dBrief/archive/refs/tags/v1.0.0.tar.gz
#     shasum -a 256 /tmp/dbrief.tar.gz
#
class Dbrief < Formula
  desc "Menu bar app that records, transcribes, and AI-summarizes meetings"
  homepage "https://github.com/Arc86/dBrief"
  url "https://github.com/Arc86/dBrief/archive/refs/tags/v1.1.0.tar.gz"
  sha256 "745a03ef60880e849bc39082997fb8a3b042b49cbf145b8d9e48d293bb87dab6"
  license "MIT"
  head "https://github.com/Arc86/dBrief.git", branch: "main"

  depends_on xcode: ["16.0", :build]
  depends_on arch: :arm64
  depends_on "ffmpeg"
  depends_on macos: :sonoma # macOS 14+
  depends_on "yt-dlp" => :recommended

  def install
    # SwiftPM cannot apply its own sandbox while running inside Homebrew's build
    # sandbox (sandbox-exec: sandbox_apply: Operation not permitted), so patch the
    # build command to pass --disable-sandbox.
    inreplace "Makefile", "--arch arm64", "--arch arm64 --disable-sandbox"
    system "make", "app"
    prefix.install "dBrief.app"
  end

  def caveats
    <<~EOS
      dBrief was compiled locally and installed to:
        #{opt_prefix}/dBrief.app

      Because it was built on this machine, macOS Gatekeeper will not block it.
      To make it appear in /Applications and Launchpad, symlink it:
        ln -sf "#{opt_prefix}/dBrief.app" /Applications/dBrief.app

      Optional: `yt-dlp` enables transcribing YouTube / video URLs.
    EOS
  end

  test do
    assert_path_exists prefix/"dBrief.app/Contents/MacOS/dBrief"
  end
end
