# Guards the `$GITHUB_OUTPUT` encoding used by bin/index-branding.
#
# This is the boundary where per-repo branding — free-form prose that comes from
# data-index/configs.yml, not from the repo being built — crosses into a GitHub
# Actions step output. The `name=value` form truncates at the first newline, so
# a multi-line description would spill its remaining lines into the file as
# *new* `key=value` pairs and let configs.yml define arbitrary step outputs.
# Only the heredoc form is safe, and it is only safe while the delimiter cannot
# be guessed or collided with.
require "github_output"

RSpec.describe GithubOutput do
  describe ".block" do
    it "emits the heredoc form, never `name=value`" do
      block = described_class.block("title", "IANA Index")

      expect(block).to match(/\Atitle<<(\S+)\nIANA Index\n\1\n\z/)
    end

    it "round-trips a multi-line value intact" do
      # The failure this prevents: with `name=value`, "b" and "c" below would be
      # parsed as further output assignments rather than as part of the value.
      block = described_class.block("description", "a\nb\nc")
      delimiter = block[/\Adescription<<(\S+)\n/, 1]

      expect(block).to eq("description<<#{delimiter}\na\nb\nc\n#{delimiter}\n")
    end

    it "emits an empty value as an empty line between the delimiters" do
      # Load-bearing: an unset favicon must reach the build step as "", which
      # relaton-cli treats as absent. A missing block would leave the output
      # undefined instead.
      block = described_class.block("favicon", "")
      delimiter = block[/\Afavicon<<(\S+)\n/, 1]

      expect(block).to eq("favicon<<#{delimiter}\n\n#{delimiter}\n")
    end

    it "normalises CRLF and lone CR to LF" do
      # A stray \r survives the runner into the env var and then into the
      # rendered <meta name="description">.
      block = described_class.block("description", "a\r\nb\rc")

      expect(block).to include("\na\nb\nc\n")
      expect(block).not_to include("\r")
    end

    it "picks an unpredictable delimiter on every call" do
      # If the delimiter were fixed, a description containing that exact line
      # would close the heredoc early and everything after it would be parsed as
      # further output assignments — the injection this form exists to stop.
      delimiters = Array.new(5) { described_class.block("k", "v")[/\Ak<<(\S+)\n/, 1] }

      expect(delimiters.uniq.size).to eq(5)
      expect(delimiters).to all(match(/\A\S{16,}\z/))
    end

    it "raises when a line of the value equals the delimiter" do
      # GitHub's parser fails the step when a value *line* is exactly the
      # delimiter (containing it is fine). Unreachable with a random delimiter,
      # but asserted so the guard cannot be dropped as dead code.
      expect { described_class.block("k", "a\nDELIM\nb", delimiter: "DELIM") }
        .to raise_error(ArgumentError, /delimiter/)
    end

    it "accepts a value that merely contains the delimiter within a line" do
      expect { described_class.block("k", "xDELIMx", delimiter: "DELIM") }
        .not_to raise_error
    end

    it "stringifies a non-string value" do
      # A nil reaching $GITHUB_OUTPUT would silently emit an empty block rather
      # than fail; make the coercion explicit and total.
      expect(described_class.block("k", nil)).to match(/\Ak<<(\S+)\n\n\1\n\z/)
    end
  end

  describe ".render" do
    it "returns every pair as one string, so the file is written in a single call" do
      # Atomicity matters: if the script died between two writes, a dangling
      # heredoc opener would corrupt the outputs of every *later* step in the
      # job, not just this one.
      rendered = described_class.render("title" => "IANA Index", "favicon" => "")

      expect(rendered).to be_a(String)
      expect(rendered).to start_with("title<<")
      expect(rendered).to include("\nfavicon<<")
    end

    it "gives each pair its own delimiter" do
      rendered = described_class.render("a" => "1", "b" => "2")
      delimiters = rendered.scan(/^[ab]<<(\S+)$/).flatten

      expect(delimiters.uniq.size).to eq(2)
    end
  end
end
