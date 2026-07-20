class ClaudeSandbox < Formula
  desc "Run Claude Code in a container, one profile per project directory"
  homepage "https://github.com/oglimmer/claude-sandbox"
  url "https://github.com/oglimmer/claude-sandbox/archive/refs/tags/v1.2.0.tar.gz"
  sha256 ""
  license "MIT"

  # Docker itself is a cask (Docker Desktop / OrbStack), so it can't be a
  # dependency here — `claude-sandbox` checks for the daemon at run time.
  depends_on "jq"
  depends_on "git"

  def install
    # The compose file, its build context and the baseline settings travel
    # together and are read-only: the script resolves its own symlink to find
    # them, and keeps everything mutable in ~/.claude-sandbox instead, so a
    # `brew upgrade` never touches a profile or its session history.
    # sandbox-CLAUDE.md is part of the Docker build context (the Dockerfile
    # COPYs it), so it has to travel with them or the image build fails.
    libexec.install "docker-compose.yml", "Dockerfile", "entrypoint.sh",
                    "claude-settings.json", "sandbox-CLAUDE.md",
                    ".env.example", "oglimmer.sh",
                    "docker-compose.override.yml.example"

    # Same script, second name. Invoked as `claude-sandbox` it defaults to
    # "start the sandbox for this directory"; the repo checkout keeps calling it
    # ./oglimmer.sh for the management commands.
    bin.install_symlink libexec/"oglimmer.sh" => "claude-sandbox"
  end

  def caveats
    <<~EOS
      Profiles, their state and .env live in ~/.claude-sandbox — created on
      first run and preserved across upgrades. Override with CLAUDE_SANDBOX_HOME.

      Requires a running Docker daemon (Docker Desktop or OrbStack). The first
      run in a project builds the sandbox image, which takes a few minutes:

        cd ~/dev/my-project
        claude-sandbox --create
    EOS
  end

  test do
    assert_match "claude-sandbox", shell_output("#{bin}/claude-sandbox --help")
    assert_match "--create", shell_output("#{bin}/claude-sandbox --help")
  end
end
