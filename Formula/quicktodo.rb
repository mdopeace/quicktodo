class Quicktodo < Formula
  desc "Minimal menu-bar todo app for macOS"
  homepage "https://github.com/mdopeace/quicktodo"
  url "https://github.com/mdopeace/quicktodo/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "PLACEHOLDER_FILLED_BY_RELEASE_SCRIPT"

  depends_on :macos
  depends_on :xcode => :build

  def install
    system "./scripts/package.sh", "local"
    prefix.install "dist/quicktodo.app"
  end

  def caveats
    <<~EOS
      quicktodo.app installed to:
        #{opt_prefix}/quicktodo.app

      To launch:
        open "#{opt_prefix}/quicktodo.app"

      To add to /Applications, use "Check for Updates" in the app menu.
    EOS
  end

  test do
    assert_predicate opt_prefix/"quicktodo.app/Contents/MacOS/QuickTodo", :executable?
  end
end