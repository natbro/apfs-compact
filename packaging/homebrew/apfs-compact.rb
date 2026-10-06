class ApfsCompact < Formula
  desc "Replace duplicate and near-duplicate files with APFS clones"
  homepage "https://github.com/natbro/apfs-compact"
  url "https://github.com/natbro/apfs-compact/archive/refs/tags/v0.1.1.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT-0"
  head "https://github.com/natbro/apfs-compact.git", branch: "main"

  depends_on xcode: ["15.0", :build]
  depends_on macos: :ventura

  def install
    system "swift", "build", "--disable-sandbox", "--configuration", "release"
    bin.install ".build/release/apfs-compact"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/apfs-compact --version")

    # Two identical files in separate directories: a dry run must find one to clone.
    (testpath/"a").mkpath
    (testpath/"b").mkpath
    (testpath/"a/data").write("apfs-compact" * 10_000)
    (testpath/"b/data").write("apfs-compact" * 10_000)
    output = shell_output("#{bin}/apfs-compact scan --granularity 16k #{testpath}/a #{testpath}/b")
    assert_match "Files to replace with clones: 1", output
  end
end
