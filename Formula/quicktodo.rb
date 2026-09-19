class Quicktodo < Formula
  desc "Minimal menu-bar todo app for macOS"
  homepage "https://github.com/mdopeace/quicktodo"
  url "https://github.com/mdopeace/quicktodo/archive/refs/tags/v1.1.0.tar.gz"
  sha256 "42436183baa5c0fb8f9b99e764c73a0e9d35a5992e9e3a7ed70756ee8b6d0ab2"

  depends_on :macos
  depends_on :xcode => :build

  def install
    system "./scripts/package.sh", "local"
    libexec.install "dist/quicktodo.app"
  end

  def caveats
    <<~EOS
      quicktodo.app installed to:
        #{opt_libexec}/quicktodo.app

      To launch it:
        open "#{opt_libexec}/quicktodo.app"

      To add to /Applications:
        cp -R "#{opt_libexec}/quicktodo.app" /Applications/
    EOS
  end

  test do
    assert_predicate opt_libexec/"quicktodo.app/Contents/MacOS/QuickTodo", :executable?
  end
end