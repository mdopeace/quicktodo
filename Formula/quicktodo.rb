class Quicktodo < Formula
  desc "Minimal menu-bar todo app for macOS"
  homepage "https://github.com/mdopeace/quicktodo"
  url "https://github.com/mdopeace/quicktodo/archive/refs/tags/v1.1.3.tar.gz"
  sha256 "7bde45e1534b3751e8966561aabf98c65f7ed133c124e22900ac97425091674b"

  depends_on :macos
  depends_on :xcode => :build

  def install
    system "./scripts/package.sh", "local"
    libexec.install "dist/quicktodo.app"
  end

  def caveats
    <<~EOS
      quicktodo.app installed to:
        \#{opt_libexec}/quicktodo.app

      To launch it:
        open "\#{opt_libexec}/quicktodo.app"

      To add to /Applications:
        cp -R "\#{opt_libexec}/quicktodo.app" /Applications/
    EOS
  end

  test do
    assert_predicate opt_libexec/"quicktodo.app/Contents/MacOS/QuickTodo", :executable?
  end
end
