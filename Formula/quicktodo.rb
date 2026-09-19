class Quicktodo < Formula
  desc "Minimal menu-bar todo app for macOS"
  homepage "https://github.com/mdopeace/quicktodo"
  url "https://github.com/mdopeace/quicktodo/archive/refs/tags/v1.1.1.tar.gz"
  sha256 "ed4a052fd2972f961c74326cc131025298e19c0b79ad1bd56d99dc8072c602cd"

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